import AppKit
import Foundation

struct QuotaSnapshot {
    let usedPercent: Double
    let remainingPercent: Int
    let windowDurationMinutes: Int
    let resetsAt: Date?
    let planType: String?
    let updatedAt: Date
}

enum CodexQuotaError: LocalizedError {
    case chatGPTNotInstalled
    case bundledCodexMissing(String)
    case processLaunchFailed(String)
    case connectionTimedOut
    case requestTimedOut
    case malformedMessage(String)
    case serverError(code: Int?, message: String)
    case missingRateLimitBucket
    case missingRateLimitWindow
    case invalidUsedPercent(Double)

    var errorDescription: String? {
        switch self {
        case .chatGPTNotInstalled:
            return "没有找到 ChatGPT.app，请先安装并登录 ChatGPT。"
        case let .bundledCodexMissing(path):
            return "ChatGPT 内置的 Codex 不存在或不可执行：\(path)"
        case let .processLaunchFailed(reason):
            return "Codex App Server 启动失败：\(reason)"
        case .connectionTimedOut:
            return "连接 Codex App Server 超时。"
        case .requestTimedOut:
            return "读取额度超时。"
        case let .malformedMessage(reason):
            return "Codex 返回了无法识别的数据：\(reason)"
        case let .serverError(code, message):
            if let code {
                return "Codex 返回错误 \(code)：\(message)"
            }
            return "Codex 返回错误：\(message)"
        case .missingRateLimitBucket:
            return "Codex 响应里没有主额度信息。"
        case .missingRateLimitWindow:
            return "Codex 主额度里没有可用的时间窗口。"
        case let .invalidUsedPercent(value):
            return "Codex 返回了无效的已用比例：\(value)"
        }
    }
}

final class CodexRateLimitClient {
    var onSnapshot: ((QuotaSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.local.codex-quota.app-server")
    private var process: Process?
    private var standardInputHandle: FileHandle?
    private var standardOutputBuffer = Data()
    private var standardErrorTail = ""
    private var isInitialized = false
    private var isStopping = false
    private var nextRequestID = 1
    private var rateLimitRequestID: Int?

    func start() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.isStopping = false
            self.startProcessIfNeeded()
        }
    }

    func refresh() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.process?.isRunning != true {
                self.startProcessIfNeeded()
                return
            }
            self.requestRateLimitsIfPossible()
        }
    }

    func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.process?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading }?.readabilityHandler = nil
            self.process?.standardError.flatMap { ($0 as? Pipe)?.fileHandleForReading }?.readabilityHandler = nil
            try? self.standardInputHandle?.close()
            if self.process?.isRunning == true {
                self.process?.terminate()
            }
            self.resetConnectionState()
        }
    }

    private func startProcessIfNeeded() {
        guard process?.isRunning != true else { return }

        do {
            let executableURL = try locateBundledCodex()
            let launchedProcess = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            launchedProcess.executableURL = executableURL
            launchedProcess.arguments = ["app-server"]
            launchedProcess.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            launchedProcess.standardInput = inputPipe
            launchedProcess.standardOutput = outputPipe
            launchedProcess.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { return }
                self?.ioQueue.async {
                    self?.consumeStandardOutput(bytes)
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { return }
                self?.ioQueue.async {
                    self?.rememberStandardError(bytes)
                }
            }

            launchedProcess.terminationHandler = { [weak self, weak launchedProcess] finishedProcess in
                self?.ioQueue.async {
                    guard let self, let launchedProcess, self.process === launchedProcess else { return }
                    let exitCode = finishedProcess.terminationStatus
                    let diagnostic = self.standardErrorTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.resetConnectionState()

                    guard !self.isStopping else { return }
                    let reason = diagnostic.isEmpty
                        ? "进程已退出，状态码 \(exitCode)"
                        : "进程已退出，状态码 \(exitCode)：\(diagnostic)"
                    self.report(CodexQuotaError.processLaunchFailed(reason))
                    self.ioQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, !self.isStopping else { return }
                        self.startProcessIfNeeded()
                    }
                }
            }

            process = launchedProcess
            standardInputHandle = inputPipe.fileHandleForWriting
            standardOutputBuffer.removeAll(keepingCapacity: true)
            standardErrorTail = ""
            isInitialized = false
            rateLimitRequestID = nil

            do {
                try launchedProcess.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                resetConnectionState()
                throw CodexQuotaError.processLaunchFailed(error.localizedDescription)
            }

            try send([
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "codex_quota_dock",
                        "title": "Codex Quota Dock",
                        "version": "0.1.0",
                    ],
                ],
            ])

            ioQueue.asyncAfter(deadline: .now() + 10) { [weak self, weak launchedProcess] in
                guard
                    let self,
                    let launchedProcess,
                    self.process === launchedProcess,
                    !self.isInitialized
                else { return }

                self.report(CodexQuotaError.connectionTimedOut)
                launchedProcess.terminate()
            }
        } catch {
            resetConnectionState()
            report(error)
        }
    }

    private func locateBundledCodex() throws -> URL {
        let fileManager = FileManager.default
        let fallbackApplicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? (fileManager.fileExists(atPath: fallbackApplicationURL.path) ? fallbackApplicationURL : nil)

        guard let applicationURL else {
            throw CodexQuotaError.chatGPTNotInstalled
        }

        let executableURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw CodexQuotaError.bundledCodexMissing(executableURL.path)
        }
        return executableURL
    }

    private func consumeStandardOutput(_ bytes: Data) {
        standardOutputBuffer.append(bytes)
        let newline = Data([0x0A])

        while let newlineRange = standardOutputBuffer.range(of: newline) {
            let line = standardOutputBuffer.subdata(in: standardOutputBuffer.startIndex..<newlineRange.lowerBound)
            standardOutputBuffer.removeSubrange(standardOutputBuffer.startIndex...newlineRange.lowerBound)
            guard !line.isEmpty else { continue }

            do {
                let decoded = try JSONSerialization.jsonObject(with: line)
                guard let message = decoded as? [String: Any] else {
                    throw CodexQuotaError.malformedMessage("顶层数据不是对象")
                }
                try handle(message)
            } catch {
                report(error)
            }
        }
    }

    private func handle(_ message: [String: Any]) throws {
        if let responseID = integer(from: message["id"]) {
            if responseID == 0 {
                if let serverError = message["error"] as? [String: Any] {
                    throw decodeServerError(serverError)
                }
                guard message["result"] != nil else {
                    throw CodexQuotaError.malformedMessage("initialize 响应缺少 result")
                }

                try send(["method": "initialized", "params": [:]])
                isInitialized = true
                requestRateLimitsIfPossible()
                return
            }

            guard responseID == rateLimitRequestID else { return }
            rateLimitRequestID = nil

            if let serverError = message["error"] as? [String: Any] {
                throw decodeServerError(serverError)
            }
            guard let result = message["result"] as? [String: Any] else {
                throw CodexQuotaError.malformedMessage("额度响应缺少 result")
            }

            let snapshot = try decodeQuotaSnapshot(result)
            DispatchQueue.main.async { [weak self] in
                self?.onSnapshot?(snapshot)
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method == "account/rateLimits/updated" || method == "account/updated" {
            requestRateLimitsIfPossible()
        }
    }

    private func requestRateLimitsIfPossible() {
        guard isInitialized, process?.isRunning == true, rateLimitRequestID == nil else { return }

        let requestID = nextRequestID
        nextRequestID += 1
        rateLimitRequestID = requestID

        do {
            try send(["method": "account/rateLimits/read", "id": requestID])
        } catch {
            rateLimitRequestID = nil
            report(error)
            return
        }

        ioQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.rateLimitRequestID == requestID else { return }
            self.rateLimitRequestID = nil
            self.report(CodexQuotaError.requestTimedOut)
            self.process?.terminate()
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let standardInputHandle else {
            throw CodexQuotaError.processLaunchFailed("标准输入尚未建立")
        }
        var encoded = try JSONSerialization.data(withJSONObject: message)
        encoded.append(0x0A)
        try standardInputHandle.write(contentsOf: encoded)
    }

    private func decodeQuotaSnapshot(_ result: [String: Any]) throws -> QuotaSnapshot {
        let mainBucket: [String: Any]?
        if
            let buckets = result["rateLimitsByLimitId"] as? [String: Any],
            let codexBucket = buckets["codex"] as? [String: Any]
        {
            mainBucket = codexBucket
        } else {
            mainBucket = result["rateLimits"] as? [String: Any]
        }

        guard let mainBucket else {
            throw CodexQuotaError.missingRateLimitBucket
        }

        var windows: [(usedPercent: Double, durationMinutes: Int, resetsAt: Date?)] = []
        for key in ["primary", "secondary"] {
            guard let window = mainBucket[key] as? [String: Any] else { continue }
            guard let usedPercent = number(from: window["usedPercent"]) else {
                throw CodexQuotaError.malformedMessage("\(key).usedPercent 缺失")
            }
            guard (0...100).contains(usedPercent) else {
                throw CodexQuotaError.invalidUsedPercent(usedPercent)
            }

            let durationMinutes = integer(from: window["windowDurationMins"]) ?? 0
            let resetsAt = number(from: window["resetsAt"]).map(Date.init(timeIntervalSince1970:))
            windows.append((usedPercent, durationMinutes, resetsAt))
        }

        guard let limitingWindow = windows.max(by: { $0.usedPercent < $1.usedPercent }) else {
            throw CodexQuotaError.missingRateLimitWindow
        }

        let remainingPercent = max(0, min(100, Int((100 - limitingWindow.usedPercent).rounded())))
        return QuotaSnapshot(
            usedPercent: limitingWindow.usedPercent,
            remainingPercent: remainingPercent,
            windowDurationMinutes: limitingWindow.durationMinutes,
            resetsAt: limitingWindow.resetsAt,
            planType: mainBucket["planType"] as? String,
            updatedAt: Date()
        )
    }

    private func decodeServerError(_ serverError: [String: Any]) -> CodexQuotaError {
        let code = integer(from: serverError["code"])
        let message = serverError["message"] as? String ?? "未知错误"
        return .serverError(code: code, message: message)
    }

    private func number(from value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func integer(from value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func rememberStandardError(_ bytes: Data) {
        guard let text = String(data: bytes, encoding: .utf8) else { return }
        standardErrorTail += text
        if standardErrorTail.count > 4_096 {
            standardErrorTail = String(standardErrorTail.suffix(4_096))
        }
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    private func resetConnectionState() {
        if let outputPipe = process?.standardOutput as? Pipe {
            outputPipe.fileHandleForReading.readabilityHandler = nil
        }
        if let errorPipe = process?.standardError as? Pipe {
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }
        process = nil
        standardInputHandle = nil
        isInitialized = false
        rateLimitRequestID = nil
        standardOutputBuffer.removeAll(keepingCapacity: false)
    }
}
