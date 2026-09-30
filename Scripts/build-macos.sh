#!/usr/bin/env bash
# Native macOS uses the login Keychain; no Catalyst provisioning is needed.
set -euo pipefail
RELAY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_OUTPUT="${1:-$RELAY_ROOT/build/macos}"
RELAY_ARCH="$(uname -m)"
case "$RELAY_ARCH" in arm64|x86_64) ;; *) printf 'Unsupported Mac architecture\n' >&2; exit 1;; esac
RELAY_APP="$RELAY_OUTPUT/Relay.app"
mkdir -p "$RELAY_APP/Contents/MacOS" "$RELAY_APP/Contents/Resources"
RELAY_SOURCES=()
while IFS= read -r -d '' source; do RELAY_SOURCES+=("$source"); done < <(find "$RELAY_ROOT/Relay" -name '*.swift' -print0)
xcrun swiftc -parse-as-library -swift-version 5 -target "$RELAY_ARCH-apple-macos14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" "${RELAY_SOURCES[@]}" \
  -o "$RELAY_APP/Contents/MacOS/Relay"
cat > "$RELAY_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Relay</string>
<key>CFBundleIdentifier</key><string>com.example.codexrelay.mac</string>
<key>CFBundleName</key><string>Relay</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your private Codex host over Tailscale.</string>
</dict></plist>
PLIST
cp "$RELAY_ROOT/Relay/PrivacyInfo.xcprivacy" "$RELAY_APP/Contents/Resources/"
# Ad-hoc signing supports a local native build. It is not a notarized release.
codesign --force --sign - --identifier com.example.codexrelay.mac "$RELAY_APP"
codesign --verify --strict "$RELAY_APP"
printf 'Built %s\n' "$RELAY_APP"
