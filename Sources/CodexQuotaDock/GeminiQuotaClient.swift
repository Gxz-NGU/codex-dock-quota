import AppKit
import Foundation

struct GeminiBucket: Decodable {
    let bucketId: String
    let remainingFraction: Double?
    let resetTime: String?
    var percent: Int { Int((remainingFraction! * 100).rounded()) }
}
struct GeminiQuota {
    let fiveHour: GeminiBucket
    let weekly: GeminiBucket?
    static func decode(_ data: Data) throws -> GeminiQuota {
        struct Group: Decodable { let buckets: [GeminiBucket] }
        struct Response: Decodable { let groups: [Group] }
        struct Envelope: Decodable { let response: Response }
        let buckets = try JSONDecoder().decode(Envelope.self, from: data).response.groups.flatMap(\.buckets)
        func read(_ id: String, required: Bool) throws -> GeminiBucket? {
            let matches = buckets.filter { $0.bucketId == id }
            if matches.isEmpty && !required { return nil }
            guard matches.count == 1 else { throw GeminiError.message("\(id) 数量错误：\(matches.count)") }
            let bucket = matches[0]
            guard let fraction = bucket.remainingFraction, fraction.isFinite, (0...1).contains(fraction) else { throw GeminiError.message("\(id) remainingFraction 无效") }
            if let reset = bucket.resetTime, ISO8601DateFormatter().date(from: reset) == nil { throw GeminiError.message("\(id) resetTime 无效：\(reset)") }
            return bucket
        }
        return try GeminiQuota(fiveHour: read("gemini-5h", required: true)!, weekly: read("gemini-weekly", required: false))
    }
}
enum GeminiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

actor GeminiQuotaClient {
    private let appPath = "/Applications/Antigravity IDE.app"
    private let owner = UUID().uuidString
    private var directory: URL?
    private var lastPID: Int32?
    private var renderedPercent: Int?
    private var busy = false
    private var stopping = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }()
    private struct AppProcess { let pid: Int32; let parent: Int32; let command: String }
    private func run(_ executable: String, _ arguments: [String], allowEmpty: Bool = false) throws -> String {
        return try autoreleasepool {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if allowEmpty && process.terminationStatus == 1 && bytes.isEmpty && errorBytes.isEmpty { return "" }
        guard process.terminationStatus == 0 else { throw GeminiError.message("\(executable) 执行失败：\(process.terminationStatus)") }
        return String(decoding: bytes, as: UTF8.self)
        }
    }
    private func processes() throws -> [AppProcess] {
        try run("/bin/ps", ["-axo", "pid=,ppid=,command="]).split(separator: "\n").map { line in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { throw GeminiError.message("无法解析进程列表") }
            return AppProcess(pid: pid, parent: parent, command: String(fields[2]))
        }
    }
    private func isApp(_ row: AppProcess) -> Bool {
        let executable = appPath + "/Contents/MacOS/Electron"
        return row.command == executable || row.command.hasPrefix(executable + " ")
    }
    private func listeners(_ pid: Int32) throws -> [String] {
        let output = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"], allowEmpty: true)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let index = fields.firstIndex(of: "TCP"), fields.indices.contains(index + 1) else { return nil }
            return String(fields[index + 1])
        }
    }
    private func request(_ url: URL, body: Data? = nil, token: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw GeminiError.message("本地接口 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)") }
        return bytes
    }
    private func readQuota(_ rows: [AppProcess], pid: Int32) async throws -> GeminiQuota {
        let servers = rows.filter { $0.parent == pid && $0.command.hasPrefix(appPath + "/Contents/Resources/app/extensions/antigravity/bin/language_server") }
        guard servers.count == 1 else { throw GeminiError.message("IDE 主额度服务数量错误：\(servers.count)") }
        let server = servers[0]
        let expression = try NSRegularExpression(pattern: "--csrf_token(?:=|\\s+)(\\S+)")
        guard let match = expression.firstMatch(in: server.command, range: NSRange(server.command.startIndex..., in: server.command)), let range = Range(match.range(at: 1), in: server.command) else { throw GeminiError.message("本地额度服务缺少 CSRF 信息") }
        let token = String(server.command[range])
        var failures: [String] = []
        for address in try listeners(server.pid) where address.hasPrefix("127.0.0.1:") {
            do {
                let url = URL(string: "http://\(address)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")!
                return try GeminiQuota.decode(await request(url, body: Data("{\"forceRefresh\":true}".utf8), token: token))
            } catch { failures.append(error.localizedDescription) }
        }
        throw GeminiError.message("额度读取失败：" + failures.joined(separator: "；"))
    }
    func readOnly() async throws -> GeminiQuota {
        let rows = try processes(), apps = rows.filter(isApp)
        guard apps.count == 1 else { throw GeminiError.message("请保持一个 Antigravity IDE 实例运行（当前 \(apps.count) 个）") }
        return try await readQuota(rows, pid: apps[0].pid)
    }
    func refresh() async throws -> GeminiQuota? {
        guard !busy && !stopping else { return nil }
        busy = true
        defer { busy = false }
        do {
            let rows = try processes(), apps = rows.filter(isApp)
            guard apps.count == 1 else { throw GeminiError.message("请保持一个 Antigravity IDE 实例运行（当前 \(apps.count) 个）") }
            let quota = try await readQuota(rows, pid: apps[0].pid)
            guard !stopping else { return nil }
            if directory == nil {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-dock-" + owner)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                directory = url
            }
            let path = directory!.path
            if renderedPercent != quota.fiveHour.percent {
                try await MainActor.run {
                    try autoreleasepool { try renderGeminiQuota(percent: quota.fiveHour.percent, directory: path) }
                }
                renderedPercent = quota.fiveHour.percent
            }
            lastPID = apps[0].pid
            try await dockCommand(apps[0].pid, restore: false)
            let status: [String: Any] = ["fiveHourPercent": quota.fiveHour.percent,
                "weeklyPercent": quota.weekly.map { $0.percent } as Any? ?? NSNull(),
                "updatedAt": ISO8601DateFormatter().string(from: Date()), "pid": apps[0].pid]
            try JSONSerialization.data(withJSONObject: status).write(to: directory!.appendingPathComponent("status.json"), options: .atomic)
            return quota
        } catch {
            let originalError = error
            do { try await restore() } catch { throw GeminiError.message("\(originalError.localizedDescription)；恢复失败：\(error.localizedDescription)（150 秒看门狗仍有效）") }
            throw originalError
        }
    }
    private func dockCommand(_ pid: Int32, restore: Bool) async throws {
        guard try processes().contains(where: { $0.pid == pid && isApp($0) }) else { throw GeminiError.message("目标 Antigravity IDE 进程已退出") }
        guard try run("/usr/sbin/lsof", ["-nP", "-iTCP:9229", "-sTCP:LISTEN"], allowEmpty: true).isEmpty else { throw GeminiError.message("9229 端口已被占用，未接管现有调试器") }
        guard kill(pid, SIGUSR1) == 0 else { throw GeminiError.message("无法开启 IDE 本机调试：\(errno)") }
        var ready = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if try listeners(pid).contains("127.0.0.1:9229") { ready = true; break }
        }
        guard ready else { throw GeminiError.message("IDE 调试端口未就绪") }
        struct Target: Decodable { let webSocketDebuggerUrl: String }
        let targets = try JSONDecoder().decode([Target].self, from: await request(URL(string: "http://127.0.0.1:9229/json/list")!))
        guard targets.count == 1, let url = URL(string: targets[0].webSocketDebuggerUrl), url.host == "127.0.0.1", url.port == 9229 else { throw GeminiError.message("调试目标地址无效") }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let command: [String: Any] = ["owner": owner, "directory": directory!.path, "pid": pid, "restore": restore, "package": appPath + "/Contents/Resources/app/package.json"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        let expression = """
        (()=>{const inspector=process.getBuiltinModule('inspector');try{
        const c=\(json);const {app,nativeImage}=process.getBuiltinModule('module').createRequire(c.package)('electron');
        if(process.pid!==c.pid||app.getName()!=='Antigravity IDE')throw Error('应用身份不匹配');
        let s=globalThis.__antigravityGeminiDock;
        if(s&&s.owner!==c.owner)throw Error('另一个额度工具正在管理图标');
        if(c.restore){if(s){clearTimeout(s.timer);s.restore();}return {restored:true};}
        if(!s){const original=nativeImage.createFromPath(c.directory+'/original.png');if(original.isEmpty())throw Error('原图标为空');
        s={owner:c.owner,restore:()=>{app.dock.setIcon(original);delete globalThis.__antigravityGeminiDock;}};globalThis.__antigravityGeminiDock=s;}
        const image=nativeImage.createFromPath(c.directory+'/quota.png');if(image.isEmpty())throw Error('额度图标为空');
        clearTimeout(s.timer);s.timer=setTimeout(()=>s.restore(),150000);app.dock.setIcon(image);return {updated:true};
        }finally{setTimeout(()=>inspector.close(),100);}})()
        """
        let packet: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": expression, "returnByValue": true]]
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: packet), as: UTF8.self)))
        let timeout = Task { try await Task.sleep(nanoseconds: 10_000_000_000); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel() }
        while true {
            let message = try await socket.receive()
            let bytes: Data
            switch message { case let .data(data): bytes = data; case let .string(text): bytes = Data(text.utf8); @unknown default: throw GeminiError.message("未知调试响应") }
            guard let reply = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GeminiError.message("无效调试响应") }
            guard (reply["id"] as? Int) == 1 else { continue }
            if reply["error"] != nil || (reply["result"] as? [String: Any])?["exceptionDetails"] != nil { throw GeminiError.message("Dock 更新失败：\(String(decoding: bytes, as: UTF8.self))") }
            break
        }
        socket.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if try !listeners(pid).contains("127.0.0.1:9229") { return }
        }
        throw GeminiError.message("更新完成但临时调试端口尚未关闭")
    }
    private func restore() async throws {
        guard let pid = lastPID else { return }
        if try processes().contains(where: { $0.pid == pid && isApp($0) }) { try await dockCommand(pid, restore: true) }
        lastPID = nil
    }
    func stop() async throws {
        stopping = true
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        try await restore()
        if let directory { try FileManager.default.removeItem(at: directory) }
        session.invalidateAndCancel()
    }
}
