#!/bin/bash
# Builds "build/Power Gauge.app" from Sources/PowerGauge using the Command Line Tools (no Xcode needed).
#   scripts/build.sh
# The app's name, identifier and version are in Resources/Info.plist.
# The app icon is precompiled: Resources/Icon/Assets.car and AppIcon.icns are made from
# Resources/Icon/AppIcon.icon by
#   scripts/make-icon.sh Resources/Icon/AppIcon.icon Resources/Icon
# That step alone needs the full Xcode 26 (actool); rerun it only when the icon source changes.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Power Gauge.app"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" Resources/Info.plist)"

# Swift 5.4, the Command Line Tools' compiler on Big Sur, cannot read the Swift modules of a
# newer SDK, so with that compiler the Big Sur SDK is used if it is there. The sources'
# compiler-version checks rely on each Swift building with its own SDK like this.
BIG_SUR_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX11.3.sdk
SDK=()
if [ -d "$BIG_SUR_SDK" ]; then
	case "$(swiftc --version 2>&1)" in
	*"Swift version 5.4"*) SDK=(-sdk "$BIG_SUR_SDK") ;;
	esac
fi

# The new app is put together and signed in a temporary folder and replaces the old one only
# once it is complete, so a build that fails at any step leaves the old app as it was.
STAGE="$(mktemp -d -t PowerGauge)"
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/$(basename "$APP")"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"

# Built for macOS 11 so that the checks for newer systems' features are real; the app is Intel-only.
# The kernel's diagnostic call (Sources/CDiag) is C, since Swift has no inline assembly; its
# header is the Swift sources' bridging header.
CSDK=()
if [ ${#SDK[@]} -gt 0 ]; then CSDK=(-isysroot "$BIG_SUR_SDK"); fi
clang -O2 ${CSDK[@]+"${CSDK[@]}"} -target x86_64-apple-macos11.0 -I Sources/CDiag/include -c Sources/CDiag/CDiag.c -o "$STAGE/CDiag.o"
# The Swift sources are in folders by what they do (see docs/architecture.md's Layout).
SOURCES=()
while IFS= read -r FILE; do SOURCES+=("$FILE"); done < <(find Sources/PowerGauge -name '*.swift' | sort)
swiftc -O ${SDK[@]+"${SDK[@]}"} -target x86_64-apple-macos11.0 -module-name PowerGauge \
	-import-objc-header Sources/CDiag/include/CDiag.h \
	"${SOURCES[@]}" "$STAGE/CDiag.o" -o "$NEW/Contents/MacOS/$EXECUTABLE"

# Icon: Assets.car holds the layered Liquid Glass icon (macOS 26+) and bitmaps for macOS 11-15, found
# through CFBundleIconName; AppIcon.icns is the flat fallback, found through CFBundleIconFile.
cp Resources/Icon/Assets.car Resources/Icon/AppIcon.icns "$NEW/Contents/Resources/"
cp Resources/Info.plist "$NEW/Contents/Info.plist"

codesign --force -s - "$NEW"

mkdir -p build
rm -rf "$APP"
mv "$NEW" "$APP"
# macOS caches icons per bundle path and bundle modification time; a fresh time makes it re-read the icon.
touch "$APP"
echo "Built $(pwd)/$APP"
