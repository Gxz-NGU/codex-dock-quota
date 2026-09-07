<div align="center">
  <h1>AI Quota · Codex & Gemini Dock Indicators</h1>
  <p>One Swift menu-bar app. Remaining quota on ChatGPT and Antigravity IDE's own Dock icons.</p>
  <p>
    <img src="docs/chatgpt-dock-quota.png" width="170" alt="ChatGPT Dock icon with Codex remaining quota and progress bar">
    &nbsp;&nbsp;
    <img src="docs/antigravity-gemini-quota.png" width="170" alt="Antigravity IDE icon with Gemini five-hour remaining quota and progress bar">
  </p>
  <p>Codex on ChatGPT · Gemini on Antigravity IDE</p>
  <p><a href="README.zh-CN.md">简体中文</a></p>
</div>

The images illustrate the rendered quota icons; their percentages are examples, not live account data.

> [!IMPORTANT]
> An unofficial, experimental macOS utility. Codex uses the documented [App Server protocol](https://developers.openai.com/codex/app-server/), but both Dock integrations depend on application internals. Antigravity updates briefly use its local Electron main-process debugger, which can execute code inside the IDE. Future application updates may require compatibility changes.

## Features

| Provider | Original Dock icon | Displayed quota |
| --- | --- | --- |
| Codex | ChatGPT | Most constrained active window in the main `codex` bucket |
| Gemini | Antigravity IDE | Remaining **five-hour shared Gemini pool** (`gemini-5h`) |

- Percentage and proportional white progress bar on each original Dock icon; no extra Dock icon.
- Gemini weekly remaining quota and five-hour reset time in the shared menu-bar menu.
- Refresh every 60 seconds, after wake, or manually from the menu.
- Native Swift quota reading, WebSocket communication and image rendering. No Node runtime or Node background process.
- One utility process plus ChatGPT's bundled Codex App Server child process. Memory usage varies; fewer processes do not guarantee lower memory use.
- Gemini icons redraw only when their percentage changes; ChatGPT supports light and dark icons.
- Normal quit restores both icons. Gemini also has a 150-second restoration watchdog if refreshes stop.
- Provider failures are reported separately. Missing Gemini quota is not presented as 0% or 100%.

## Requirements

- macOS 13.5 or later; tested locally on Apple Silicon.
- Installed, signed-in ChatGPT with its bundled Codex executable and `CodexDockTilePlugin`.
- Installed, signed-in **Antigravity IDE** at `/Applications/Antigravity IDE.app`, running as a single instance.
- Swift 5.9 or later to build. No Node.js installation is needed.

## Build and run

```sh
./scripts/build_unified_app.sh
open "dist/AI Quota.app"
```

`./scripts/build_app.sh` is an alias for the same build. The output is ad-hoc signed for local use, not Apple-notarized. No login item is installed automatically.

Use the menu-bar gauge icon to inspect both providers, refresh, open ChatGPT, or choose **退出并恢复两个图标** (quit and restore both icons). On migration, AI Quota asks the old Codex Quota and Antigravity Quota utilities to quit normally before taking over; it does not quit ChatGPT or Antigravity IDE.

The existing **v0.1.0** [release](https://github.com/Gxz-NGU/codex-dock-quota/releases/tag/v0.1.0) is the earlier Codex-only build. Build from current source for the unified version. To create a local DMG, use `./scripts/package_release.sh`; this does not publish a release.

## How it works

**Codex:** starts ChatGPT's bundled `codex app-server`, performs the initialization handshake, reads `account/rateLimits/read`, and selects `rateLimitsByLimitId["codex"]`. It renders `100 - usedPercent` for the most constrained active window and asks ChatGPT's existing Dock plugin to load the generated icons.

**Gemini:** discovers the local language server directly owned by the Antigravity IDE main process, then calls `RetrieveUserQuotaSummary`. It selects exactly `gemini-5h` and rounds `remainingFraction × 100`; `gemini-weekly` is shown separately in the menu. The main icon therefore does not tell you whether the weekly pool is exhausted.

For each Gemini Dock update, the utility verifies the IDE process, briefly opens its Inspector on `127.0.0.1:9229`, invokes `app.dock.setIcon()`, and closes the debugger. An occupied port causes an error; the utility does not take over another debugger. Gemini quota failures trigger restoration of the original icon, with the in-process watchdog as a fallback.

## Privacy and compatibility

- Does not modify or re-sign ChatGPT or Antigravity IDE.
- Does not read browser cookies or Keychain credentials; no separate API keys are required.
- The local language server's CSRF value is used in memory only for requests to that service.
- Gemini icons and minimal quota/update metadata are stored in a private temporary directory, removed on normal quit. No analytics are included.
- ChatGPT's Dock preference keys/plugin notifications and Antigravity's quota/debugger interfaces are not stable public integration contracts.
- Multiple IDE instances, other Antigravity installation paths, and reading Gemini quota while the IDE is closed are not supported.

## Tests

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/native-test-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/native-test-cache" \
swift test --scratch-path .build/native-tests --disable-sandbox
```

Tests cover exact Gemini pool selection, 0%, rounding/reset times, and missing, duplicate or malformed quota data. Local checks also exercised real quota reads, refreshes, migration, normal quit/restoration, child-process shutdown and debugger-port closure. Icon files alone are not proof of visible Dock updates; the original Dock update path was also confirmed visually by the user.

## Source layout

```text
Sources/CodexQuotaDock/
  CodexRateLimitClient.swift       Codex App Server client
  ChatGPTDockIconController.swift  ChatGPT icon rendering and Dock plugin
  GeminiQuotaClient.swift          Native quota reader and local Inspector client
  GeminiQuotaIcon.swift            Gemini icon renderer
  main.swift                      Shared menu, refresh and lifecycle
Tests/NativeQuotaTests/            Gemini response validation tests
scripts/build_unified_app.sh       Native app build
scripts/package_release.sh         Local DMG packaging
```

## License

MIT. See [LICENSE](LICENSE).

ChatGPT, Codex and OpenAI are trademarks of OpenAI. Gemini and Antigravity are Google product names. This project is not affiliated with or endorsed by OpenAI or Google.
