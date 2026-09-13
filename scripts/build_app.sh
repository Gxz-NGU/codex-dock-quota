#!/bin/zsh
set -euo pipefail
project_directory=${0:A:h:h}
cd "$project_directory"
export CLANG_MODULE_CACHE_PATH="$project_directory/.build/split-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --scratch-path .build/split --disable-sandbox
binary_directory=$(swift build -c release --scratch-path .build/split --show-bin-path --disable-sandbox)
for kind in codex gemini; do
  if [[ "$kind" == codex ]]; then
    app_name='Codex Quota'; binary_name=CodexQuotaDock; bundle_id=com.local.codex-quota-dock
  else
    app_name='Antigravity Quota'; binary_name=AntigravityQuotaDock; bundle_id=local.antigravity-gemini-quota
  fi
  app_directory="$project_directory/dist/$app_name.app"
  mkdir -p "$app_directory/Contents/MacOS"
  cp "$binary_directory/$binary_name" "$app_directory/Contents/MacOS/$binary_name"
  cp Resources/Info.plist "$app_directory/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app_directory/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app_directory/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $binary_name" "$app_directory/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_directory/Contents/Info.plist"
  # Clear only the obsolete Node prototype's named resources, when present.
  for old_file in node worker.mjs quota.mjs; do
    rm -f "$app_directory/Contents/Resources/$old_file"
  done
  codesign --force --sign - "$app_directory"
  print "$app_directory"
done
