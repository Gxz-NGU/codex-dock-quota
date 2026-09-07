<div align="center">
  <h1>AI Quota · Codex 与 Gemini Dock 额度</h1>
  <p>一个 Swift 菜单栏 App，在 ChatGPT 和 Antigravity IDE 原 Dock 图标上显示剩余额度。</p>
  <p>
    <img src="docs/chatgpt-dock-quota.png" width="170" alt="ChatGPT 原 Dock 图标上的 Codex 剩余百分比和进度条">
    &nbsp;&nbsp;
    <img src="docs/antigravity-gemini-quota.png" width="170" alt="Antigravity IDE 图标上的 Gemini 五小时剩余额度和进度条">
  </p>
  <p>ChatGPT：Codex 额度 · Antigravity IDE：Gemini 额度</p>
  <p><a href="README.md">English</a></p>
</div>

图片展示工具渲染的额度图标，百分比仅作示例，并非实时账号数据。

> [!IMPORTANT]
> 这是一个非官方实验项目。Codex 使用已公开说明的 [App Server 协议](https://developers.openai.com/codex/app-server/)，两个 Dock 集成都依赖目标应用的内部实现。Antigravity 图标更新会短暂使用本机 Electron 主进程调试接口，该接口具有在 IDE 内执行代码的能力。目标应用升级后可能需要适配。

## 功能

| 来源 | 显示位置 | 主图标显示内容 |
| --- | --- | --- |
| Codex | ChatGPT 原 Dock 图标 | 主 `codex` 额度中约束最紧的有效时间窗口 |
| Gemini | Antigravity IDE 原 Dock 图标 | **Gemini 共用池的 5 小时剩余额度**（`gemini-5h`） |

- 在两个原 Dock 图标上绘制百分比和白色比例进度条，不额外创建 Dock 图标。
- 共用一个菜单栏入口，查看 Gemini 周额度、5 小时重置时间和两路状态。
- 每 60 秒、Mac 唤醒后自动刷新，也可手动刷新。
- 额度读取、WebSocket 通信和图标渲染均使用 Swift，无需 Node，也不启动 Node 后台进程。
- 常驻进程为一个工具 App 和一个 ChatGPT 内置 Codex App Server 子进程。内存随运行状态波动，进程减少不保证内存更低。
- Gemini 百分比变化时才重绘；ChatGPT 支持明暗两套图标。
- 正常退出恢复两个图标；Gemini 额外提供 150 秒无成功刷新自动恢复保护。
- 两路错误分别展示，不把缺失的 Gemini 额度当成 0% 或 100%。

## 环境要求

- macOS 13.5 或更高版本；已在 Apple Silicon 本机验证。
- 已安装并登录 ChatGPT，当前版本包含 Codex 可执行文件及 `CodexDockTilePlugin`。
- 已安装并登录 **Antigravity IDE**，路径为 `/Applications/Antigravity IDE.app`，且保持单实例运行。
- 构建需要 Swift 5.9 或更高版本，不需要安装 Node.js。

## 构建与运行

```sh
./scripts/build_unified_app.sh
open "dist/AI Quota.app"
```

`./scripts/build_app.sh` 也会构建同一个统一版。应用仅作本机临时签名，未经 Apple 公证；不会自动添加登录项。

点击菜单栏仪表图标，可查看两路额度、立即刷新、打开 ChatGPT，或选择“退出并恢复两个图标”。首次迁移时会请求旧 Codex Quota 和 Antigravity Quota 正常退出，待恢复后接管；不会退出 ChatGPT 或 Antigravity IDE。

现有 **v0.1.0** [Release](https://github.com/Gxz-NGU/codex-dock-quota/releases/tag/v0.1.0) 为旧 Codex 单独版。统一版请从当前源码构建。运行 `./scripts/package_release.sh` 可生成本地 DMG，不会自动发布 Release。

## 实现原理

**Codex：** 启动 ChatGPT 内置的 `codex app-server`，完成初始化后调用 `account/rateLimits/read`，选择 `rateLimitsByLimitId["codex"]` 中约束最紧的有效窗口，计算 `100 - usedPercent`。在原始图标副本上绘制额度后，通过 ChatGPT 已有的 Dock 插件加载。

**Gemini：** 从 Antigravity IDE 主进程的直接子进程中定位本地语言服务，调用 `RetrieveUserQuotaSummary`。精确选择 `gemini-5h`，将 `remainingFraction × 100` 四舍五入；`gemini-weekly` 单独显示在菜单中。因此主图标不代表周额度是否仍可用。

每次 Gemini Dock 更新都核对 IDE 进程身份，短暂开启 `127.0.0.1:9229` Inspector，调用 `app.dock.setIcon()` 后关闭调试端口。如果端口已被占用，会明确报错，不接管其他调试器。额度读取失败会尝试恢复原图标，IDE 进程内的看门狗提供后备恢复。

## 隐私与兼容性

- 不修改或重新签名 ChatGPT、Antigravity IDE 安装包。
- 不读取浏览器 Cookie 或 Keychain 登录凭据，无需额外 API Key。
- 本地语言服务的 CSRF 信息仅在内存中用于对应服务请求。
- Gemini 图标及最少量的额度、更新时间元数据存放在私有临时目录，正常退出清理；不包含统计上报。
- ChatGPT Dock 配置及插件通知、Antigravity 本地额度及调试接口均不是稳定的公开集成约定。
- 当前不支持多个 IDE 实例、其他 Antigravity 安装路径，以及 IDE 关闭后的额度读取。

## 测试

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/native-test-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/native-test-cache" \
swift test --scratch-path .build/native-tests --disable-sandbox
```

测试覆盖 Gemini 共用池精确选择、0% 边界、取整和重置时间，以及缺失、重复和异常数据。本机另已验证真实读取、刷新、旧版迁移、正常退出恢复、子进程结束及调试端口关闭。生成图标文件本身不代表 Dock 实际显示成功；原 Dock 更新路径也经过用户目视确认。

更详细的使用说明见[统一版说明](docs/unified-quota.zh-CN.md)。

## 项目结构

```text
Sources/CodexQuotaDock/
  CodexRateLimitClient.swift       Codex App Server 客户端
  ChatGPTDockIconController.swift  ChatGPT 图标渲染及 Dock 插件
  GeminiQuotaClient.swift          原生额度读取及本机 Inspector 客户端
  GeminiQuotaIcon.swift            Gemini 图标渲染
  main.swift                      统一菜单、刷新及生命周期
Tests/NativeQuotaTests/            Gemini 响应校验测试
scripts/build_unified_app.sh       原生应用构建
scripts/package_release.sh         本地 DMG 打包
```

## 许可证

MIT，详见 [LICENSE](LICENSE)。

ChatGPT、Codex 和 OpenAI 是 OpenAI 的商标；Gemini 和 Antigravity 是 Google 的产品名称。本项目与 OpenAI 或 Google 无隶属或背书关系。
