#!/bin/zsh
set -eu
cd "${0:A:h:h}"
fixture_root=$(/usr/bin/mktemp -d /private/tmp/codex-accounts-lifecycle.XXXXXX)
fixture_app="$fixture_root/Fixture With Spaces.app"
fixture_id="local.codex.accounts.fixture.$(/usr/bin/uuidgen)"
mkdir -p "$fixture_app/Contents/MacOS"
cat > "$fixture_root/Fixture.swift" <<'SWIFT'
import AppKit
import CryptoKit
let fixtureRoot = Bundle.main.bundleURL.deletingLastPathComponent()
let fixtureAuth = fixtureRoot.appendingPathComponent("fixture-auth.json")
if let data = try? Data(contentsOf: fixtureAuth) {
    let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    try? digest.write(to:fixtureRoot.appendingPathComponent("loaded-auth-digest.txt"),atomically:true,encoding:.utf8)
    // Fixture-only renderer confirmation, using the inspected owner-key algorithm.
    // It never discovers or reads the real CODEX_HOME.
    let stateURL = fixtureRoot.appendingPathComponent("fixture-global-state.json")
    if let stateData = try? Data(contentsOf:stateURL),
       var state = try? JSONSerialization.jsonObject(with:stateData) as? [String:Any],
       let auth = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
       let tokens = auth["tokens"] as? [String:Any], let token = tokens["id_token"] as? String,
       let account = tokens["account_id"] as? String {
        let parts = token.split(separator:".")
        if parts.count == 3 {
            var part=String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
            part += String(repeating:"=",count:(4-part.count%4)%4)
            if let bytes=Data(base64Encoded:part), let claims=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
               let identity=claims["https://api.openai.com/auth"] as? [String:Any], let user=identity["chatgpt_user_id"] as? String,
               let ownerData=try? JSONSerialization.data(withJSONObject:[user,account],options:[.withoutEscapingSlashes]) {
                state["electron-renderer-content-owner"]=SHA256.hash(data:ownerData).map { String(format:"%02x",$0) }.joined()
                if let updated=try? JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]) { try? updated.write(to:stateURL,options:.atomic) }
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
SWIFT
/usr/bin/swiftc "$fixture_root/Fixture.swift" -o "$fixture_app/Contents/MacOS/ChatGPT"
cat > "$fixture_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$fixture_id</string>
<key>CFBundleExecutable</key><string>ChatGPT</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$fixture_app"
CODEX_ACCOUNTS_FIXTURE_APP="$fixture_app" swift test
# The test closes its unique fixture. Retain the small fixture directory for failure diagnosis.
