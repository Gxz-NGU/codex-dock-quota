#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
build_directory="$project_directory/.build"
application_directory="$project_directory/dist/Codex Quota.app"

export CLANG_MODULE_CACHE_PATH="$build_directory/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_directory/module-cache"

cd "$project_directory"
/usr/bin/swift build -c release
binary_directory=$(/usr/bin/swift build -c release --show-bin-path)

/bin/rm -rf "$application_directory"
/bin/mkdir -p "$application_directory/Contents/MacOS"
/bin/cp "$binary_directory/CodexQuotaDock" "$application_directory/Contents/MacOS/CodexQuotaDock"
/bin/cp "$project_directory/Resources/Info.plist" "$application_directory/Contents/Info.plist"
/bin/chmod 755 "$application_directory/Contents/MacOS/CodexQuotaDock"
/usr/bin/codesign --force --sign - "$application_directory"

/usr/bin/printf '%s\n' "$application_directory"
