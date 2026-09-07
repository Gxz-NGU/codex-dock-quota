import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let geminiClient = GeminiQuotaClient()
    private var geminiSnapshot: GeminiQuota?
    private var geminiError: String?
    private var quitting = false
    private var cleanupFinished = false
    private var started = false
    private var terminationSignal: DispatchSourceSignal?
    private let rateLimitClient = CodexRateLimitClient()
    private let dockIconController = ChatGPTDockIconController()
    private var quotaRefreshTimer: Timer?
    private var badgeRefreshTimer: Timer?
    private var statusItem: NSStatusItem?
    private var lastBadgeText: String?
    private var lastSnapshot: QuotaSnapshot?
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let identifier = Bundle.main.bundleIdentifier ?? "com.local.codex-quota-dock"
        let previous = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if previous.contains(where: { $0.bundleURL == Bundle.main.bundleURL }) { NSApp.terminate(nil); return }
        let oldGemini = NSRunningApplication.runningApplications(withBundleIdentifier: "local.antigravity-gemini-quota")
        let retiring = previous + oldGemini
        for app in retiring {
            guard app.terminate() else {
                let alert = NSAlert(); alert.messageText = "无法退出旧额度工具"
                alert.informativeText = app.localizedName ?? "未知应用"; alert.runModal()
                NSApp.terminate(nil); return
            }
        }
        configureStatusItem()
        Task { @MainActor in
            for _ in 0..<150 {
                if retiring.allSatisfy({ $0.isTerminated }) { self.startQuotaUpdates(); return }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            self.displayError("旧额度工具尚未退出，未启动新额度连接；请退出旧工具后重启。")
        }
    }

    private func startQuotaUpdates() {
        guard !quitting else { return }
        started = true
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume(); terminationSignal = source
        connectRateLimitClient()
        observeChatGPTLifecycle()

        quotaRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.rateLimitClient.refresh()
            self?.refreshGemini()
        }
        badgeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reapplyLastBadge()
        }

        rateLimitClient.start()
        refreshGemini()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard started else { return }
        quotaRefreshTimer?.invalidate()
        badgeRefreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rateLimitClient.stop()
        dockIconController.restoreOriginalIcon()
    }

    private func refreshGemini() {
        guard !quitting else { return }
        Task { @MainActor in
            do {
                if let snapshot = try await geminiClient.refresh() {
                    geminiSnapshot = snapshot; geminiError = nil
                }
            } catch { geminiSnapshot = nil; geminiError = error.localizedDescription }
            rebuildStatusMenu()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard started else { quitting = true; return .terminateNow }
        if cleanupFinished { return .terminateNow }
        if quitting { return .terminateCancel }
        quitting = true
        quotaRefreshTimer?.invalidate(); badgeRefreshTimer?.invalidate()
        rateLimitClient.stop(); dockIconController.restoreOriginalIcon()
        Task { @MainActor in
            do { try await geminiClient.stop() }
            catch {
                let alert = NSAlert(); alert.messageText = "Gemini 图标恢复失败"
                alert.informativeText = error.localizedDescription + "；150 秒看门狗将恢复图标。"
                alert.runModal()
            }
            cleanupFinished = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "AI 额度"
        )
        statusItem.button?.toolTip = "Codex 额度正在连接"
        self.statusItem = statusItem
        rebuildStatusMenu()
    }

    private func connectRateLimitClient() {
        rateLimitClient.onSnapshot = { [weak self] snapshot in
            self?.display(snapshot)
        }
        rateLimitClient.onError = { [weak self] message in
            self?.displayError(message)
        }
    }

    private func observeChatGPTLifecycle() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func display(_ snapshot: QuotaSnapshot) {
        guard !quitting else { return }
        let badgeText = "\(snapshot.remainingPercent)%"
        lastSnapshot = snapshot
        lastBadgeText = badgeText
        lastError = nil

        do {
            try dockIconController.showBadge(badgeText)
            statusItem?.button?.toolTip = "Codex 剩余 \(badgeText)"
        } catch {
            lastError = error.localizedDescription
            statusItem?.button?.toolTip = error.localizedDescription
        }
        rebuildStatusMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.reapplyLastBadge()
        }
    }

    private func displayError(_ message: String) {
        guard !quitting else { return }
        lastError = message
        if lastSnapshot == nil {
            lastBadgeText = "!"
            try? dockIconController.showBadge("!")
        }
        statusItem?.button?.toolTip = message
        rebuildStatusMenu()
    }

    private func reapplyLastBadge() {
        guard !quitting else { return }
        guard let lastBadgeText else { return }
        do {
            try dockIconController.showBadge(lastBadgeText)
        } catch {
            lastError = error.localizedDescription
            statusItem?.button?.toolTip = error.localizedDescription
            rebuildStatusMenu()
        }
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        func label(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        label("Codex")

        if let snapshot = lastSnapshot {
            let remainingItem = NSMenuItem(
                title: "剩余 \(snapshot.remainingPercent)%",
                action: nil,
                keyEquivalent: ""
            )
            remainingItem.isEnabled = false
            menu.addItem(remainingItem)

            let usageItem = NSMenuItem(
                title: "\(windowDescription(snapshot.windowDurationMinutes))额度 · 已用 \(formattedPercent(snapshot.usedPercent))%",
                action: nil,
                keyEquivalent: ""
            )
            usageItem.isEnabled = false
            menu.addItem(usageItem)

            if let resetsAt = snapshot.resetsAt {
                let resetItem = NSMenuItem(
                    title: "重置：\(dateFormatter.string(from: resetsAt))",
                    action: nil,
                    keyEquivalent: ""
                )
                resetItem.isEnabled = false
                menu.addItem(resetItem)
            }
        } else {
            let loadingItem = NSMenuItem(title: "正在读取 Codex 额度…", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
        }

        if let lastError {
            let errorItem = NSMenuItem(title: "错误：\(lastError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())
        label("Antigravity IDE · Gemini 共用池")
        if let snapshot = geminiSnapshot {
            label("5 小时剩余：\(snapshot.fiveHour.percent)%")
            if let reset = snapshot.fiveHour.resetTime, let date = ISO8601DateFormatter().date(from: reset) {
                label("重置：\(dateFormatter.string(from: date))")
            }
            if let weekly = snapshot.weekly { label("周额度剩余：\(weekly.percent)%") }
        } else { label(geminiError ?? "正在读取 Gemini 额度…") }
        statusItem?.button?.toolTip = "Codex \(lastBadgeText ?? "…") · Gemini 5h \(geminiSnapshot.map { "\($0.fiveHour.percent)%" } ?? "!")"
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshQuota), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 ChatGPT", action: #selector(openChatGPT), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出并恢复两个图标", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func formattedPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func windowDescription(_ minutes: Int) -> String {
        switch minutes {
        case 300:
            return "5 小时"
        case 10_080:
            return "7 天"
        case 1_440:
            return "24 小时"
        case let value where value > 0 && value.isMultiple(of: 1_440):
            return "\(value / 1_440) 天"
        case let value where value > 0 && value.isMultiple(of: 60):
            return "\(value / 60) 小时"
        case let value where value > 0:
            return "\(value) 分钟"
        default:
            return "当前"
        }
    }

    @objc private func refreshQuota() {
        refreshGemini()
        rateLimitClient.refresh()
    }

    @objc private func workspaceDidWake() {
        refreshGemini()
        rateLimitClient.refresh()
        reapplyLastBadge()
    }

    @objc private func workspaceApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if application.bundleURL?.path == "/Applications/Antigravity IDE.app" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshGemini() }
        }
        guard application.bundleIdentifier == "com.openai.codex" else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.reapplyLastBadge()
        }
    }

    @objc private func openChatGPT() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            displayError("没有找到 ChatGPT.app。")
            return
        }

        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.displayError("打开 ChatGPT 失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
