#!/bin/zsh
set -euo pipefail
script_directory=${0:A:h}
project_directory=${script_directory:h}
release_directory="$project_directory/dist/release"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_directory/Resources/Info.plist")
architecture=$(/usr/bin/uname -m)
staging_directory=$(/usr/bin/mktemp -d /private/tmp/quota-release.XXXXXX)
trap '/bin/rm -rf -- "$staging_directory"' EXIT
"$script_directory/build_app.sh"
mkdir -p "$release_directory"
for app_name in 'Codex Quota' 'Antigravity Quota'; do
    image_name=${app_name// /-}
    disk_image_path="$release_directory/${image_name}-v${version}-macOS-${architecture}.dmg"
    folder="$staging_directory/$app_name"
    mkdir -p "$folder"
    ditto "$project_directory/dist/$app_name.app" "$folder/$app_name.app"
    ln -s /Applications "$folder/Applications"
    hdiutil create -volname "$app_name" -srcfolder "$folder" -format UDZO -ov "$disk_image_path" >/dev/null
    (cd "$release_directory" && shasum -a 256 "${disk_image_path:t}" > "${disk_image_path:t}.sha256")
    print "$disk_image_path"
done
