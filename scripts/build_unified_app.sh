#!/bin/zsh
set -euo pipefail
script_directory=${0:A:h}
print -u2 'AI Quota 已拆为两个独立 App，正在构建 Codex Quota 和 Antigravity Quota。'
exec "$script_directory/build_app.sh"
