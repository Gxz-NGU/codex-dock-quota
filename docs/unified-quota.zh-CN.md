# 从 AI Quota 迁移

AI Quota 统一版已拆为两个独立的原生 Swift App：Codex Quota 与 Antigravity Quota。

先退出旧 AI Quota，再按需启动一个或两个新工具。启动 Codex Quota 也会请求旧统一版正常退出；不会退出 ChatGPT 或 Antigravity IDE。新工具各自刷新、各自恢复图标，不自动启动另一工具。

构建命令为 `./scripts/build_app.sh`，产物位于 `dist/Codex Quota.app` 和 `dist/Antigravity Quota.app`。完整说明见 [README](../README.zh-CN.md)。旧 `dist/legacy/AI Quota.app` 作为回退文件保留，请不要与新工具同时运行。
