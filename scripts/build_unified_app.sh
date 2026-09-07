#!/bin/zsh
set -euo pipefail
project_directory=${0:A:h:h}
application_directory="$project_directory/dist/AI Quota.app"
mkdir -p "$application_directory/Contents/MacOS" "$project_directory/.build/unified-module-cache"
swiftc -O -target "$(uname -m)-apple-macosx13.5" -module-cache-path "$project_directory/.build/unified-module-cache" "$project_directory"/Sources/CodexQuotaDock/*.swift -o "$application_directory/Contents/MacOS/CodexQuotaDock"
cp "$project_directory/Resources/Info.plist" "$application_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName AI Quota' "$application_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName AI 额度' "$application_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 13.5' "$application_directory/Contents/Info.plist"
codesign --force --sign - "$application_directory"
print "$application_directory"
