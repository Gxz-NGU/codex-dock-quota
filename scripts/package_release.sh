#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_directory=${script_directory:h}
application_directory="$project_directory/dist/Codex Quota.app"
release_directory="$project_directory/dist/release"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_directory/Resources/Info.plist")
architecture=$(/usr/bin/uname -m)
disk_image_path="$release_directory/Codex-Quota-v${version}-macOS-${architecture}.dmg"
checksum_path="${disk_image_path}.sha256"
staging_directory=$(/usr/bin/mktemp -d /private/tmp/codex-quota-release.XXXXXX)

cleanup() {
    /bin/rm -rf -- "$staging_directory"
}
trap cleanup EXIT

"$script_directory/build_app.sh" >/dev/null
/bin/mkdir -p "$release_directory" "$staging_directory/Codex Quota"
/usr/bin/ditto "$application_directory" "$staging_directory/Codex Quota/Codex Quota.app"
/bin/ln -s /Applications "$staging_directory/Codex Quota/Applications"
/bin/rm -f "$disk_image_path" "$checksum_path"
/usr/bin/hdiutil create \
    -volname "Codex Quota" \
    -srcfolder "$staging_directory/Codex Quota" \
    -format UDZO \
    -ov \
    "$disk_image_path" >/dev/null
/usr/bin/shasum -a 256 "$disk_image_path" >"$checksum_path"

/usr/bin/printf '%s\n%s\n' "$disk_image_path" "$checksum_path"
