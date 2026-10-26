#!/bin/bash
# Builds "NxNative Builder.app" (scripts/NxNativeBuilder.swift), the window around build_ipa_from_nsp.py: pick the game files and the output folder, press Start.
# Usage: scripts/build_builder_app.sh [destination folder, default: the repository root]. PYTHON=<python> picks the Python the app runs the script with (default: python3 on the PATH).
# The app remembers this Python and this repository: run the script again after moving the repository or changing the Python.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
app="${1:-$repo}/NxNative Builder.app"
py=$("${PYTHON:-python3}" -c 'import sys, lz4, capstone, fontTools; print(sys.executable)') || { echo "error: ${PYTHON:-python3} needs lz4, capstone and fonttools (see scripts/build_ipa_from_nsp.py)" >&2; exit 1; }
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library "$repo/scripts/NxNativeBuilder.swift" -o "$app/Contents/MacOS/NxNativeBuilder"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NxNative Builder</string>
<key>CFBundleIdentifier</key><string>org.nxnative.builder</string>
<key>CFBundleExecutable</key><string>NxNativeBuilder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>NXPython</key><string>$py</string>
<key>NXRepo</key><string>$repo</string>
</dict></plist>
EOF
codesign --force --sign - "$app"
echo "built $app (python: $py)"
