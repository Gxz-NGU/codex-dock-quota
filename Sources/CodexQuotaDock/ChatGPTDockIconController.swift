import AppKit
import Darwin
import Foundation

enum ChatGPTDockIconError: LocalizedError {
    case chatGPTNotInstalled
    case sourceIconMissing(String)
    case imageRenderingFailed(String)
    case unsafeGeneratedIconDirectory(String)
    case preferencesWriteFailed

    var errorDescription: String? {
        switch self {
        case .chatGPTNotInstalled:
            return "没有找到 ChatGPT.app。"
        case let .sourceIconMissing(path):
            return "没有找到 ChatGPT Dock 图标素材：\(path)"
        case let .imageRenderingFailed(reason):
            return "生成 ChatGPT Dock 图标失败：\(reason)"
        case let .unsafeGeneratedIconDirectory(path):
            return "动态图标目录不安全：\(path)"
        case .preferencesWriteFailed:
            return "无法保存 ChatGPT Dock 图标设置。"
        }
    }
}

final class ChatGPTDockIconController {
    private let chatGPTBundleIdentifier = "com.openai.codex"
    private let preferenceChangedNotification = Notification.Name(
        "com.openai.codex.DockIconPreferenceChanged"
    )
    private let sharedDefaults: UserDefaults
    private let originalPreference: Any?
    private let originalResourceName: Any?
    private let generatedIconDirectory = URL(
        fileURLWithPath: "/private/tmp/CodexQuotaDock-\(getuid())",
        isDirectory: true
    )
    private var renderedBadgeText: String?

    init() {
        let defaults = UserDefaults(suiteName: chatGPTBundleIdentifier) ?? .standard
        sharedDefaults = defaults
        let currentPreference = defaults.object(forKey: "DockIconPreference")
        let currentResourceName = defaults.object(forKey: "DockIconResourceName")
        if
            let resourceName = currentResourceName as? String,
            resourceName.contains("/CodexQuotaDock")
        {
            originalPreference = "app-default"
            originalResourceName = nil
        } else {
            originalPreference = currentPreference
            originalResourceName = currentResourceName
        }
    }

    func showBadge(_ text: String) throws {
        let applicationURL = try locateChatGPTApplication()
        let resourcesURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let sourceLightIconURL = resourcesURL.appendingPathComponent("icon-codex-light.png")
        let sourceDarkIconURL = resourcesURL.appendingPathComponent("icon-codex-dark-color.png")

        try prepareGeneratedIconDirectory()

        let generatedLightIconURL = generatedIconDirectory
            .appendingPathComponent("icon-codex-light-quota.png")
        let generatedDarkIconURL = generatedIconDirectory
            .appendingPathComponent("icon-codex-dark-color-quota.png")

        let resourceName = relativePath(from: resourcesURL, to: generatedLightIconURL)
        if
            renderedBadgeText == text,
            FileManager.default.fileExists(atPath: generatedLightIconURL.path),
            FileManager.default.fileExists(atPath: generatedDarkIconURL.path),
            sharedDefaults.string(forKey: "DockIconPreference") == "codex-system",
            sharedDefaults.string(forKey: "DockIconResourceName") == resourceName
        {
            notifyDockIconPlugin()
            return
        }

        try renderIcon(source: sourceLightIconURL, destination: generatedLightIconURL, badgeText: text)
        try renderIcon(source: sourceDarkIconURL, destination: generatedDarkIconURL, badgeText: text)

        sharedDefaults.set("codex-system", forKey: "DockIconPreference")
        sharedDefaults.set(resourceName, forKey: "DockIconResourceName")
        guard sharedDefaults.synchronize() else {
            throw ChatGPTDockIconError.preferencesWriteFailed
        }
        renderedBadgeText = text
        notifyDockIconPlugin()
    }

    func restoreOriginalIcon() {
        restore(originalPreference, forKey: "DockIconPreference")
        restore(originalResourceName, forKey: "DockIconResourceName")
        _ = sharedDefaults.synchronize()
        notifyDockIconPlugin()
        renderedBadgeText = nil
        try? FileManager.default.removeItem(at: generatedIconDirectory)
    }

    private func prepareGeneratedIconDirectory() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: generatedIconDirectory.path) {
            let values = try generatedIconDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ChatGPTDockIconError.unsafeGeneratedIconDirectory(
                    generatedIconDirectory.path
                )
            }
        } else {
            try fileManager.createDirectory(
                at: generatedIconDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: generatedIconDirectory.path
        )
    }

    private func locateChatGPTApplication() throws -> URL {
        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: chatGPTBundleIdentifier
        ) {
            return applicationURL
        }

        let fallbackURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            throw ChatGPTDockIconError.chatGPTNotInstalled
        }
        return fallbackURL
    }

    private func renderIcon(source: URL, destination: URL, badgeText: String) throws {
        guard let sourceImage = NSImage(contentsOf: source) else {
            throw ChatGPTDockIconError.sourceIconMissing(source.path)
        }
        guard
            let sourceRepresentation = sourceImage.representations.max(by: {
                $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
            }),
            sourceRepresentation.pixelsWide > 0,
            sourceRepresentation.pixelsHigh > 0
        else {
            throw ChatGPTDockIconError.imageRenderingFailed("无法读取像素尺寸：\(source.path)")
        }

        let width = sourceRepresentation.pixelsWide
        let height = sourceRepresentation.pixelsHigh
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ChatGPTDockIconError.imageRenderingFailed("无法创建 \(width)x\(height) 位图")
        }

        let canvas = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            throw ChatGPTDockIconError.imageRenderingFailed("无法创建绘图上下文")
        }
        NSGraphicsContext.current = graphicsContext
        NSColor.clear.setFill()
        canvas.fill()
        sourceImage.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
        drawBadge(badgeText, in: canvas)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ChatGPTDockIconError.imageRenderingFailed("PNG 编码失败")
        }
        try pngData.write(to: destination, options: .atomic)
    }

    private func drawBadge(_ text: String, in canvas: NSRect) {
        let iconSize = min(canvas.width, canvas.height)
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: iconSize * 0.135,
            weight: .bold
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let horizontalPadding = iconSize * 0.052
        let verticalPadding = iconSize * 0.025
        let badgeWidth = max(iconSize * 0.25, textSize.width + horizontalPadding * 2)
        let badgeHeight = textSize.height + verticalPadding * 2
        let margin = iconSize * 0.065
        let badgeRect = NSRect(
            x: canvas.maxX - margin - badgeWidth,
            y: canvas.maxY - margin - badgeHeight,
            width: badgeWidth,
            height: badgeHeight
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = iconSize * 0.018
        shadow.shadowOffset = NSSize(width: 0, height: -iconSize * 0.008)
        shadow.set()
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeHeight * 0.28,
            yRadius: badgeHeight * 0.28
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        let textOrigin = NSPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func relativePath(from baseDirectory: URL, to destination: URL) -> String {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        var commonComponentCount = 0

        while
            commonComponentCount < baseComponents.count,
            commonComponentCount < destinationComponents.count,
            baseComponents[commonComponentCount] == destinationComponents[commonComponentCount]
        {
            commonComponentCount += 1
        }

        let parentComponents = Array(
            repeating: "..",
            count: baseComponents.count - commonComponentCount
        )
        let childComponents = destinationComponents.dropFirst(commonComponentCount)
        return (parentComponents + childComponents).joined(separator: "/")
    }

    private func restore(_ originalValue: Any?, forKey key: String) {
        if let originalValue {
            sharedDefaults.set(originalValue, forKey: key)
        } else {
            sharedDefaults.removeObject(forKey: key)
        }
    }

    private func notifyDockIconPlugin() {
        DistributedNotificationCenter.default().postNotificationName(
            preferenceChangedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
