#!/bin/sh
set -e
cd "$(dirname "$0")"
# ARCHS: space-separated list (arm64, x86_64); several are merged into one universal binary.
ARCHS=${ARCHS:-$(uname -m)}
APP=${APP:-build/NoiseSharpening.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
BINARIES=""
for arch in $ARCHS; do
    swift build -c release --arch "$arch"
    BINARIES="$BINARIES $(swift build -c release --arch "$arch" --show-bin-path)/NoiseSharpening"
done
lipo -create $BINARIES -output "$APP/Contents/MacOS/NoiseSharpening"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
IDENTITY="${SIGN_IDENTITY:-Noise Sharpening Local Signing}"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "No '$IDENTITY' certificate in keychain; using ad-hoc signature (microphone permission resets on rebuild)"
    IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
