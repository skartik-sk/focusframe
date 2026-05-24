#!/bin/bash
set -euo pipefail

APP_NAME="FocusFrame"
CONFIGURATION="debug"
PACKAGE_ZIP=0
APP_VERSION="${FOCUSFRAME_VERSION:-1.0}"
BUILD_NUMBER="${FOCUSFRAME_BUILD_NUMBER:-1}"
BUNDLE_ID="${FOCUSFRAME_BUNDLE_ID:-com.focusframe.app}"
SIGN_IDENTITY="${FOCUSFRAME_CODESIGN_IDENTITY:--}"
FOREGROUND="${FOCUSFRAME_FOREGROUND:-1}"
BUILD_ONLY="${FOCUSFRAME_BUILD_ONLY:-0}"
if [ "${FOCUSFRAME_BACKGROUND:-0}" = "1" ]; then
    FOREGROUND=0
fi

for arg in "$@"; do
    case "$arg" in
        --foreground)
            FOREGROUND=1
            ;;
        --background)
            FOREGROUND=0
            ;;
        --build-only)
            BUILD_ONLY=1
            ;;
        --release)
            CONFIGURATION="release"
            BUILD_ONLY=1
            ;;
        --package)
            CONFIGURATION="release"
            BUILD_ONLY=1
            PACKAGE_ZIP=1
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: ./run.sh [--foreground] [--background] [--build-only] [--release] [--package]"
            exit 2
            ;;
    esac
done

BUILD_DIR=".build/${CONFIGURATION}-app-bundle"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME ($CONFIGURATION)..."
BUILD_LOG="$(mktemp -t focusframe-build.XXXXXX)"
if ! swift build -c "$CONFIGURATION" >"$BUILD_LOG" 2>&1; then
    echo "Build failed:"
    cat "$BUILD_LOG"
    rm -f "$BUILD_LOG"
    exit 1
fi
tail -3 "$BUILD_LOG"
rm -f "$BUILD_LOG"

EXECUTABLE=".build/$CONFIGURATION/FocusFrame"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Build product not found at $EXECUTABLE"
    exit 1
fi

pkill -x "$APP_NAME" 2>/dev/null || true

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

RESOURCE_BUNDLE=".build/$CONFIGURATION/FocusFrame_FocusFrame.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

ICON_FILE="Sources/FocusFrame/Resources/FocusFrame.icns"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/FocusFrame.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>FocusFrame.icns</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>FocusFrame needs access to capture your screen for recording.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>FocusFrame needs microphone access to record audio.</string>
    <key>NSCameraUsageDescription</key>
    <string>FocusFrame needs camera access for webcam overlay.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>FocusFrame uses speech recognition to generate local subtitles from recorded audio.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>FocusFrame needs input monitoring access to record keyboard shortcuts for badges.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>FocusFrame needs accessibility access as a fallback for recording keyboard shortcut badges.</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

echo "App bundle created at $APP_BUNDLE"
if [ "$PACKAGE_ZIP" = "1" ]; then
    DIST_DIR=".build/dist"
    ZIP_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION-macOS.zip"
    mkdir -p "$DIST_DIR"
    rm -f "$ZIP_PATH"
    /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_BUNDLE" "$ZIP_PATH"
    echo "Release package created at $ZIP_PATH"
fi

if [ "$BUILD_ONLY" = "1" ]; then
    echo "Build-only mode requested; not launching."
    exit 0
fi

if [ "$FOREGROUND" = "1" ]; then
    echo "Launching in foreground. Quit the app to return to the shell."
    /usr/bin/open -W -n "$APP_BUNDLE"
else
    echo "Launching..."
    /usr/bin/open -n "$APP_BUNDLE"
fi
