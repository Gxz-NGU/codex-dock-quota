# AI Quota：统一额度工具

一个 Swift 后台 App 同时更新 ChatGPT 和 Antigravity IDE 的原 Dock 图标。统一菜单展示两个来源的额度、刷新和退出控制。运行时仅保留主 App 与 ChatGPT 内置 Codex App Server 子进程；不包含 Node.js。

## 构建和启动

```sh
./scripts/build_unified_app.sh
```

打开 `dist/AI Quota.app`。需要 macOS 13.5 或更高版本和已登录的两个目标应用；构建需要 Swift。工具使用本机临时签名，未经 Apple 公证。

首次切换时，工具会请求旧 Codex Quota 和 Antigravity Quota 正常退出，等待它们恢复图标后再接管。不会退出 ChatGPT 或 Antigravity IDE。旧工具未能退出时会报错，不并行覆盖图标。当前不自动配置登录项。

## 数据和行为

- Codex 沿用本机 App Server 的 `account/rateLimits/read`，显示最紧的有效时间窗口。
- Gemini 从 Antigravity IDE 主进程的本地语言服务读取 `RetrieveUserQuotaSummary`，只选择 `gemini-5h`。菜单中额外显示 `gemini-weekly`。
- 仅额度百分比变化时重新渲染 Gemini 图标，并及时释放渲染临时对象。
- 每 60 秒刷新，唤醒后也刷新；两路分别显示错误，不让一个来源阻断另一个。
- Gemini 读取、JSON 解析、WebSocket 连接和图标渲染均由 Swift 完成，不启动 Node。
- Gemini CSRF 信息仅在内存传给对应本机服务，不读取 Keychain 或浏览器凭据。
- Gemini Dock 更新短暂启用 `127.0.0.1:9229` 调试端口，调用 Electron 主进程的 `app.dock.setIcon()`，随后关闭端口。不接管已占用的调试端口。此接口具有应用主进程代码执行权限，属于非官方运行时集成，IDE 更新可能需要适配。
- 正常退出恢复两个图标；Gemini 更新失败时尝试恢复，其 IDE 进程内另有 150 秒无刷新自动恢复保护。不会修改或重签两个目标应用。

## 测试

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/native-test-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/native-test-cache" \
swift test --scratch-path .build/native-tests --disable-sandbox
```

原生测试覆盖共用池精确选择、0% 边界、实际响应取整和重置时间，以及缺失、重复和异常数据。真实切换、图标更新、定时刷新、退出恢复和内存占用需在目标机器验证。

未支持：多个 Antigravity IDE 实例、其他 IDE 安装路径、IDE 关闭后的离线额度读取。

## 本机验证（2026-09-07）

已验证从两套旧工具切换到一个 Swift App 和一个 Codex App Server 子进程，Node 退出；真实 Gemini 额度读取和每分钟更新成功，更新后调试端口关闭。正常退出可结束两个工具进程并完成 Gemini 图标恢复、临时目录清理。修复了主线程延后退出导致清理任务等待的问题。RSS 随启动、刷新和系统内存回收明显波动，不保证固定节省比例。
