<div align="center">
  <img src="docs/chatgpt-dock-quota.png" width="170" alt="ChatGPT Dock 图标直接显示 Codex 剩余 12%">
  <h1>Codex Dock Quota</h1>
  <p>在 macOS 的 ChatGPT 原 Dock 图标上直接显示 Codex 剩余额度。</p>
  <p><a href="README.md">English</a></p>
</div>

> [!IMPORTANT]
> 这是一个非官方实验项目。额度读取使用 OpenAI 已公开说明的 [Codex App Server 协议](https://developers.openai.com/codex/app-server/)；Dock 集成依赖当前 ChatGPT 桌面版内部的 Dock Tile 插件约定，ChatGPT 更新后可能需要适配。

## 功能

- 百分比直接显示在 ChatGPT 自己的 Dock 图标上，不产生第二个 Dock 图标。
- 读取主 `codex` 额度，并显示当前约束最紧的有效时间窗口。
- 每 60 秒以及 Mac 唤醒后自动刷新。
- 同时生成明暗两套 ChatGPT Codex 图标。
- 正常退出时恢复工具启动前的 ChatGPT Dock 图标设置。
- 菜单栏提供查看状态、立即刷新、打开 ChatGPT 和退出功能。

## 环境要求

- macOS 13 或更高版本
- 已安装并登录 ChatGPT 桌面版
- ChatGPT 当前版本包含内置 Codex App Server 和 `CodexDockTilePlugin`
- 从源码构建需要 Swift 5.9 或更高版本

## 构建与运行

```bash
./scripts/build_app.sh
open "dist/Codex Quota.app"
```

工具以 `LSUIElement` 后台应用运行，因此不会创建自己的 Dock 图标。可以通过菜单栏的仪表图标刷新或退出。

## 实现原理

1. 定位 `ChatGPT.app` 内置的 `codex` 可执行文件。
2. 通过标准输入输出启动 `codex app-server`，完成 `initialize` 握手并调用 `account/rateLimits/read`。
3. 选择 `rateLimitsByLimitId["codex"]`，从约束最紧的有效窗口计算 `100 - usedPercent`。
4. 在 ChatGPT 内置的明暗 Codex 图标副本上绘制百分比。
5. 将生成的 PNG 写入 `/private/tmp` 下按用户隔离的目录，并且只在显示值变化时重绘。
6. 让 ChatGPT 已有的 `CodexDockTilePlugin` 加载这些图片，并发送插件的配置变更通知。

项目**不会**修改或重新签名 `ChatGPT.app`，不会向 ChatGPT 注入代码，不读取浏览器 Cookie，也不需要单独的 OpenAI API Key。

## 隐私与安全

- 登录和令牌刷新仍由 ChatGPT 内置的 Codex App Server 负责。
- 工具只解析展示所需的额度窗口信息。
- 动态图标里只包含渲染后的百分比。
- 不包含统计上报和第三方依赖。

## 兼容性说明

App Server 属于 OpenAI 已公开说明的协议。`DockIconPreference`、`DockIconResourceName` 以及 `CodexDockTilePlugin` 的刷新通知属于当前 macOS 客户端的实现细节。如果未来 ChatGPT 删除或修改该插件，即使额度读取仍可用，Dock 展示也可能失效。

如果工具异常退出后留下旧图标，请重新启动工具，再从菜单栏选择“退出额度角标”。正常退出会恢复启动时记录的图标设置。

## 项目结构

```text
Sources/CodexQuotaDock/
  CodexRateLimitClient.swift       Codex App Server JSONL 客户端
  ChatGPTDockIconController.swift  图标渲染与 Dock 插件刷新
  main.swift                       后台应用与菜单栏控制
Resources/Info.plist               macOS 应用信息
scripts/build_app.sh               Release 构建与 .app 打包
```

## 许可证

MIT，详见 [LICENSE](LICENSE)。

ChatGPT、Codex 和 OpenAI 是 OpenAI 的商标。本项目与 OpenAI 无隶属或背书关系。
