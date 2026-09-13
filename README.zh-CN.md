<div align="center">
  <h1>Codex Quota 与 Antigravity Quota</h1>
  <p>两个独立的 Swift 菜单栏 App，在原 Dock 图标上显示剩余额度，按需启动。</p>
  <p>
    <img src="docs/chatgpt-dock-quota.png" width="170" alt="ChatGPT 原 Dock 图标上的 Codex 额度与进度条">
    &nbsp;&nbsp;
    <img src="docs/antigravity-gemini-quota.png" width="170" alt="Antigravity IDE 原 Dock 图标上的 Gemini 额度与进度条">
  </p>
  <p><a href="README.md">English</a></p>
</div>

图片为显示效果示例，不是实时额度。

> [!IMPORTANT]
> 非官方实验工具。新版 ChatGPT 和 Antigravity IDE 的运行中图标通过本机 Electron 主进程调试接口更新，该接口具有在目标应用内执行代码的能力。不会修改或重签目标应用，但依赖内部实现，应用升级后可能需要适配。

## 两个 App，各自独立

| 工具 | 目标图标 | 主图标额度 | 常驻进程 |
| --- | --- | --- | --- |
| Codex Quota | ChatGPT | 主 `codex` 池中约束最紧的有效窗口 | 工具 + 内置 Codex App Server |
| Antigravity Quota | Antigravity IDE | Gemini 共用池 5 小时额度 | 工具本身 |

- 可只开一个，也可同时开；一个退出不会停止另一个。
- 各有菜单栏入口，不额外创建 Dock 图标，无 Node 运行时或 Node 子进程。
- 每 60 秒读取额度，支持手动刷新和 Mac 唤醒后刷新。
- Gemini 菜单还显示周剩余额度和 5 小时重置时间。主图标不表示周额度是否仍可用。
- 百分比变化时才重绘图片；图标带百分比和白色比例进度条。
- 正常退出恢复各自的图标，运行中另有 150 秒无更新恢复保护。
- 进程减少不保证内存降低；按需关闭工具可以停止相应进程。

## 构建和使用

需要 macOS 13.5+ 和 Swift 5.9+；已在 Apple Silicon 上构建。不需要安装 Node.js。

```sh
./scripts/build_app.sh

# 需要哪个，启动哪个
open "dist/Codex Quota.app"
open "dist/Antigravity Quota.app"
```

两个目标应用应已登录。Antigravity IDE 当前须位于 `/Applications/Antigravity IDE.app` 且单实例运行；IDE 关闭时不读取 Gemini 额度。Codex 需要 ChatGPT 内置的 Codex App Server。

应用仅作本机临时签名，未经 Apple 公证。不自动添加登录项，不自动启动另一个额度工具。

从统一 AI Quota 迁移：先从旧工具菜单选择退出，或启动 Codex Quota 让它请求旧统一工具正常退出；再按需启动 Antigravity Quota。请勿同时运行旧统一版和新的 Gemini 工具，以免覆盖图标。`build_unified_app.sh` 仅保留为旧命令入口，现在构建的是两个独立 App。

`./scripts/package_release.sh` 为两个 App 分别生成 DMG 和 SHA-256 文件，不会自动发布 Release。现有 v0.1.0 Release 是早期 Codex 单独版；本次适配请从当前源码构建。

## 新版 ChatGPT 图标适配

旧实现只写 `DockIconPreference` / `DockIconResourceName` 并通知 Dock 插件。新版 ChatGPT 主进程也会调用 `app.dock.setIcon()`，插件生成图片成功不等于运行中的图标显示成功。

当前实现检测 Electron 应用：在经过身份验证的目标进程内更新图标，并在工具运行期间处理应用自身再次设置图标和明暗主题切换。退出或看门狗触发时，移除临时图标处理逻辑，恢复应用最近设置的图标；如果应用期间未设置过，则恢复启动时保存的图标。旧非 Electron 版本仍使用原插件路径。

每次连接短暂开启 `127.0.0.1:9229`，操作后关闭。两个额度工具通过本机文件锁串行使用该端口；不会接管其他程序已打开的调试器。若目标版本不支持调试，会报错，不将读取成功冒充为图标更新成功。

## 数据与隐私

- Codex 使用 [App Server 协议](https://developers.openai.com/codex/app-server/) 的 `account/rateLimits/read`。
- Gemini 使用 IDE 主语言服务的 `RetrieveUserQuotaSummary`，精确选择 `gemini-5h`，四舍五入 `remainingFraction × 100`，周额度单独展示。
- 不读取浏览器 Cookie 或 Keychain；本地服务 CSRF 值仅在内存使用。
- 临时目录只保存图标和最少量的额度更新时间信息；正常退出清理。无统计上报。
- 调试脚本仅处理图标，不读取应用窗口、会话或文档内容。

## 验证

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/split-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/split-module-cache" \
swift test --scratch-path .build/split --disable-sandbox
```

测试覆盖 Gemini 共用池选择、0%、异常响应，以及运行中图标覆盖、明暗切换、恢复和错误进程拒绝。脚本测试通过不等于真实 Dock 显示通过，需在目标应用版本上目视确认。2026-09-13，新版 ChatGPT 的运行中额度图标已由用户目视确认恢复；退出恢复和调试端口关闭也已验证。

## 结构

```text
Sources/CodexQuotaDock/        Codex 额度、图标渲染和独立菜单
Sources/AntigravityQuotaDock/  Gemini 额度、图标渲染和独立菜单
Sources/QuotaShared/           两个 App 共用的 Swift 源码，运行时无需共同后台服务
Tests/NativeQuotaTests/        原生测试
scripts/build_app.sh           构建两个 App
scripts/package_release.sh     分别打包
```

MIT，详见 [LICENSE](LICENSE)。本项目与 OpenAI 或 Google 无隶属或背书关系。
