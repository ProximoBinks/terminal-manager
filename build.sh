#!/bin/bash
# Builds TerminalManager.app, a menu bar agent with no Dock icon.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TerminalManager"
BUNDLE="build/${APP_NAME}.app"

echo "Building release binary…"
swift build -c release --disable-sandbox

echo "Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/${APP_NAME}"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>Terminal Manager</string>
    <key>CFBundleIdentifier</key>      <string>com.elliotkoh.terminalmanager</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.1</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>

    <!-- Menu bar agent: no Dock icon, no main window. -->
    <key>LSUIElement</key>             <true/>

    <!-- Shown in the prompt when the app first drives Terminal.app. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Terminal Manager reads open Terminal windows so it can match them to Claude Code and Grok Build sessions, focus them, and close them.</string>

    <key>NSDownloadsFolderUsageDescription</key>
    <string>Terminal Manager checks whether a session's project folder still exists, including sessions that were started in Downloads.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Terminal Manager checks whether a session's project folder still exists, including sessions under Documents.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Terminal Manager checks whether a session's project folder still exists, including sessions on the Desktop.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps the automation permission grant stable across launches.
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || echo "note: ad-hoc signing skipped"

echo
echo "Built $BUNDLE"
echo "Run it with:      open $BUNDLE"
echo "Install it with:  cp -R $BUNDLE /Applications/"
