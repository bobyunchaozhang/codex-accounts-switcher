#!/bin/zsh
set -eu
cd "${0:A:h:h}"
architecture="${1:-$(uname -m)}"
zsh scripts/build-app.sh "$architecture"
app="$PWD/dist/$architecture/Codex Accounts.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$PWD/../release-assets"
mkdir -p "$output"
archive="$output/Codex-Accounts-$version-$architecture.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$output" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
print "$archive"
