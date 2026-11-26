#!/bin/zsh
set -eu
cd "${0:A:h:h}"
architecture="${1:-$(uname -m)}"
case "$architecture" in
    arm64|x86_64) ;;
    *) print -u2 "Usage: zsh scripts/build-app.sh [arm64|x86_64]"; exit 2 ;;
esac
version=0.1.17
scratch="$PWD/.build-$architecture"
MACOSX_DEPLOYMENT_TARGET=14.0 swift build -c release --arch "$architecture" --scratch-path "$scratch"
bin_dir=$(swift build -c release --arch "$architecture" --scratch-path "$scratch" --show-bin-path)
app="$PWD/dist/$architecture/Codex Accounts.app"
# Recreate only this generated architecture's app, so stale resources cannot ship.
if [[ -d "$app" ]]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/CodexAccounts" "$app/Contents/MacOS/CodexAccounts"
for bundle in "$bin_dir"/*.bundle(N); do
    cp -R "$bundle" "$app/Contents/Resources/"
done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexAccounts</string>
<key>CFBundleIdentifier</key><string>local.codex.accounts</string>
<key>CFBundleName</key><string>Codex Accounts</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>18</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp ../LICENSE ../THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp Assets/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
xcrun lipo "$app/Contents/MacOS/CodexAccounts" -verify_arch "$architecture"
print "$app"
