import AppKit
import Foundation

final class GeminiAppDelegate: NSObject, NSApplicationDelegate {
    private let client = GeminiQuotaClient()
    private var status: NSStatusItem!
    private var timer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var snapshot: GeminiQuota?
    private var failure: String?
    private var quitting = false
    private var stopped = false
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let id = "local.antigravity-gemini-quota"
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 { NSApp.terminate(nil); return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "G5h · …"
        started = true
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signalSource = source
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        rebuildMenu(); refresh()
    }
    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.google.antigravity-ide" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }
    @objc private func refresh() {
        guard !quitting else { return }
        Task { @MainActor in
            do { if let quota = try await client.refresh() { snapshot = quota; failure = nil } }
            catch { snapshot = nil; failure = error.localizedDescription }
            rebuildMenu()
        }
    }
    private func rebuildMenu() {
        guard status != nil else { return }
        let menu = NSMenu()
        func label(_ text: String) { let item = NSMenuItem(title: text, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        label("Antigravity IDE · Gemini 共用池")
        if let snapshot {
            status.button?.title = "G5h · \(snapshot.fiveHour.percent)%"
            label("5 小时剩余：\(snapshot.fiveHour.percent)%")
            if let weekly = snapshot.weekly { label("周额度剩余：\(weekly.percent)%") }
            if let reset = snapshot.fiveHour.resetTime, let date = ISO8601DateFormatter().date(from: reset) {
                label("重置：\(date.formatted(date: .abbreviated, time: .shortened))")
            }
        } else { status.button?.title = "G5h · !"; label(failure ?? "正在读取额度…") }
        status.button?.toolTip = failure ?? "Gemini 共用池 5 小时额度"
        menu.addItem(.separator())
        for (title, action) in [("立即刷新", #selector(refresh)), ("退出并恢复图标", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        status.menu = menu
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !started || stopped { return .terminateNow }
        if quitting { return .terminateCancel }
        quitting = true; timer?.invalidate()
        Task { @MainActor in
            do { try await client.stop() }
            catch {
                let alert = NSAlert(); alert.messageText = "Gemini 图标恢复失败"
                alert.informativeText = error.localizedDescription + "；150 秒看门狗将恢复图标。"; alert.runModal()
            }
            stopped = true; NSApp.terminate(nil)
        }
        return .terminateCancel
    }
}
let application = NSApplication.shared
let delegate = GeminiAppDelegate()
application.delegate = delegate
application.run()
