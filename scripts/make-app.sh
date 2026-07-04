#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Backend Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BackendLauncher "$APP/Contents/MacOS/BackendLauncher"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BackendLauncher</string>
    <key>CFBundleIdentifier</key>
    <string>it.generazioneai.backend-launcher</string>
    <key>CFBundleName</key>
    <string>Backend Launcher</string>
    <key>CFBundleDisplayName</key>
    <string>Backend Launcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>it.generazioneai.backend-launcher</string>
            <key>CFBundleURLSchemes</key>
            <array><string>blauncher</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

# Path del clone da cui questa build proviene: l'app lo usa per il check aggiornamenti
# in-app (git fetch nel clone) e per lanciare `make update` in Terminale. Iniettato a
# build time — sul Mac di ogni collega punta automaticamente al SUO clone.
/usr/libexec/PlistBuddy -c "Add :BLRepoPath string $(pwd)" "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "OK: $APP"
