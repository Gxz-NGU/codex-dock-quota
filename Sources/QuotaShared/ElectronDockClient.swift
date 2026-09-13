import AppKit
import Foundation
import Darwin

public enum DockConnectionError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Only updates the verified application's Dock icon; never reads renderer or conversation state.
public actor ElectronDockClient {
    private let bundleIdentifier: String
    private let owner = UUID().uuidString
    private var lastPID: Int32?
    private var applicationURL: URL?
    private var busy = false
    private var stopping = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }()

    public init(bundleIdentifier: String) { self.bundleIdentifier = bundleIdentifier }

    public func update(applicationURL: URL, light: URL, dark: URL, original: URL) async throws {
        guard !stopping else { return }
        guard !busy else { throw DockConnectionError.message("图标更新尚未完成") }
        busy = true
        defer { busy = false }
        let pid = try await MainActor.run { () throws -> Int32 in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL }
            guard apps.count == 1 else { throw DockConnectionError.message("请保持一个 \(applicationURL.lastPathComponent) 实例运行（当前 \(apps.count) 个）") }
            return apps[0].processIdentifier
        }
        self.applicationURL = applicationURL
        // Retain a previous successful owner for cleanup, but do not claim another process before setting an icon.
        let command: [String: Any] = ["action": "update", "light": light.path, "dark": dark.path, "original": original.path]
        try await execute(pid: pid, applicationURL: applicationURL, command: command)
        lastPID = pid
    }

    public func restore() async throws {
        guard let pid = lastPID, let applicationURL else { return }
        if kill(pid, 0) == 0 {
            try await execute(pid: pid, applicationURL: applicationURL, command: ["action": "restore"])
        }
        lastPID = nil
    }

    public func stop() async throws {
        stopping = true
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        try await restore()
        session.invalidateAndCancel()
    }

    private func run(_ path: String, _ arguments: [String], allowEmpty: Bool = false) throws -> String {
        try autoreleasepool {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
            defer { deadline.cancel() }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if allowEmpty && process.terminationStatus == 1 && bytes.isEmpty && errorBytes.isEmpty { return "" }
            guard process.terminationStatus == 0 else { throw DockConnectionError.message("\(path) 执行失败：\(process.terminationStatus)") }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func listens(_ pid: Int32) throws -> Bool {
        let output = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP:9229", "-sTCP:LISTEN"], allowEmpty: true)
        return output.contains("TCP 127.0.0.1:9229 (LISTEN)")
    }

    /// Serialize the two utilities without taking over an existing user's debugger.
    private func acquirePortLock() async throws -> Int32 {
        let path = "/private/tmp/ai-quota-inspector-\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DockConnectionError.message("无法打开调试端口锁：\(errno)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(descriptor); throw DockConnectionError.message("调试端口锁文件不安全")
        }
        do {
            for _ in 0..<120 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
                guard errno == EWOULDBLOCK else { throw DockConnectionError.message("调试端口锁失败：\(errno)") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw DockConnectionError.message("另一个额度工具仍在更新图标，请稍后刷新")
        } catch { close(descriptor); throw error }
    }

    private func execute(pid: Int32, applicationURL: URL, command: [String: Any]) async throws {
        let lock = try await acquirePortLock()
        defer { flock(lock, LOCK_UN); close(lock) }
        guard let bundle = Bundle(url: applicationURL), bundle.bundleIdentifier == bundleIdentifier,
              let executable = bundle.executableURL else { throw DockConnectionError.message("应用包身份不匹配") }
        let actual = try run("/bin/ps", ["-p", String(pid), "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == executable.path else { throw DockConnectionError.message("目标进程已变化：\(actual)") }
        guard try run("/usr/sbin/lsof", ["-nP", "-iTCP:9229", "-sTCP:LISTEN"], allowEmpty: true).isEmpty else {
            throw DockConnectionError.message("9229 端口已被占用，未接管已有调试器")
        }
        guard kill(pid, SIGUSR1) == 0 else { throw DockConnectionError.message("无法开启应用调试：\(errno)") }
        var ready = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if try listens(pid) { ready = true; break }
        }
        guard ready else { throw DockConnectionError.message("应用未开启本机调试端口，当前版本可能不支持") }
        struct Target: Decodable { let webSocketDebuggerUrl: String }
        let (bytes, response) = try await session.data(from: URL(string: "http://127.0.0.1:9229/json/list")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DockConnectionError.message("读取本机调试目标失败") }
        let targets = try JSONDecoder().decode([Target].self, from: bytes)
        guard targets.count == 1, let url = URL(string: targets[0].webSocketDebuggerUrl), url.host == "127.0.0.1", url.port == 9229 else {
            throw DockConnectionError.message("调试目标不是预期的本机地址")
        }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        var payload = command
        payload["owner"] = owner; payload["pid"] = pid; payload["executable"] = executable.path
        payload["package"] = applicationURL.appendingPathComponent("Contents/Resources/package.json").path
        let expression = try Self.expression(payload)
        let packet: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": expression, "returnByValue": true]]
        let timeout = Task { try await Task.sleep(nanoseconds: 10_000_000_000); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel() }
        try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: packet), as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let data: Data
            switch message { case let .data(bytes): data = bytes; case let .string(text): data = Data(text.utf8); @unknown default: throw DockConnectionError.message("未知调试响应") }
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DockConnectionError.message("调试响应不是对象") }
            guard reply["id"] as? Int == 1 else { continue }
            if reply["error"] != nil || (reply["result"] as? [String: Any])?["exceptionDetails"] != nil {
                throw DockConnectionError.message("图标更新失败：\(String(decoding: data, as: UTF8.self))")
            }
            break
        }
        socket.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if try !listens(pid) { return }
        }
        throw DockConnectionError.message("图标已更新，但临时调试端口尚未关闭")
    }

    public static func expression(_ command: [String: Any]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        return """
        (()=>{const inspector=process.getBuiltinModule('inspector');try{
          const c=\(json), req=process.getBuiltinModule('module').createRequire(c.package);
          const {app,nativeImage,nativeTheme}=req('electron');
          if(process.pid!==c.pid||process.execPath!==c.executable)throw Error('应用身份不匹配');
          let s=globalThis.__aiQuotaDock;
          if(s&&s.owner!==c.owner)throw Error('另一个额度工具正在管理图标');
          if(c.action==='restore'){if(s)s.restore();return {restored:true};}
          const light=nativeImage.createFromPath(c.light),dark=nativeImage.createFromPath(c.dark);
          if(light.isEmpty()||dark.isEmpty())throw Error('额度图标为空');
          if(!s){
            const original=nativeImage.createFromPath(c.original);
            if(original.isEmpty())throw Error('恢复图标为空');
            const setIcon=app.dock.setIcon.bind(app.dock);
            s={owner:c.owner,setIcon,originalMethod:app.dock.setIcon};
            // Preserve the app's own subsequent theme/settings icon for restoration, but keep quota visible while active.
            s.original=original;
            s.apply=()=>setIcon(nativeTheme.shouldUseDarkColorsForSystemIntegratedUI?s.dark:s.light);
            s.wrapper=image=>{s.original=image;s.apply();};
            s.restore=()=>{clearTimeout(s.timer);nativeTheme.removeListener('updated',s.apply);
              if(app.dock.setIcon===s.wrapper)app.dock.setIcon=s.originalMethod;
              setIcon(s.original);delete globalThis.__aiQuotaDock;};
            app.dock.setIcon=s.wrapper;nativeTheme.on('updated',s.apply);globalThis.__aiQuotaDock=s;
          }
          s.light=light;s.dark=dark;clearTimeout(s.timer);s.timer=setTimeout(s.restore,150000);s.apply();
          return {updated:true,pid:process.pid};
        }finally{setTimeout(()=>inspector.close(),100);}})()
        """
    }
}
