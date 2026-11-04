#!/bin/bash
# make-icon.sh - compile an Icon Composer document into the files a hand-built macOS .app needs.
#
#   scripts/make-icon.sh <path/to/AppIcon.icon> <output-dir> [minimum macOS version, default 11.0]
#
# Writes into <output-dir> (existing copies are overwritten):
#   Assets.car                 the layered Liquid Glass icon that macOS 26+ renders live (light, dark,
#                              tinted, clear), plus pre-rendered bitmaps for macOS 11-15.
#                              The bundle finds it through CFBundleIconName.
#   <Name>.icns                flattened fallback with all ten iconset sizes (824 px body on a 1024 px
#                              canvas with the drop shadow, i.e. the normal macOS icon grid).
#                              The bundle finds it through CFBundleIconFile.
#   <Name>.partial-info.plist  the Info.plist keys actool says the bundle needs.
# <Name> is the document's file name without ".icon" (AppIcon.icon -> AppIcon).
#
# Needs the full Xcode 26 or later: actool is NOT part of the Command Line Tools. The outputs are meant
# to be kept in Resources/Icon, so that building the app itself still needs only the Command Line Tools.
# Assets.car is not byte-for-byte reproducible (actool stamps the time and random IDs into it), so run
# this only when the icon source changes, not on every build.
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
	echo "usage: $0 <path/to/AppIcon.icon> <output-dir> [minimum macOS version, default 11.0]" >&2
	exit 2
fi
ICON="${1%/}"
OUT="${2%/}"
MIN="${3:-11.0}"

case "$ICON" in
	*.icon) ;;
	*) echo "error: $ICON is not an Icon Composer document (.icon)" >&2; exit 1 ;;
esac
if [ ! -f "$ICON/icon.json" ]; then
	echo "error: $ICON/icon.json not found" >&2
	exit 1
fi
NAME="$(basename "$ICON" .icon)"

if ! ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
	echo "error: actool not found. It ships only with the full Xcode (26 or later), not with the" >&2
	echo "       Command Line Tools. Active developer directory: $(xcode-select -p 2>/dev/null || echo none)" >&2
	echo "       Install Xcode, or point at it: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0 ..." >&2
	exit 1
fi

mkdir -p "$OUT"
PARTIAL="$OUT/$NAME.partial-info.plist"

# actool exits 0 on several failures (wrong --app-icon name, missing input, missing --platform), so the
# exit status alone proves nothing: check below that it reports having written the files in this run.
set +e
LOG="$("$ACTOOL" "$ICON" \
	--compile "$OUT" \
	--app-icon "$NAME" \
	--platform macosx \
	--target-device mac \
	--minimum-deployment-target "$MIN" \
	--standalone-icon-behavior all \
	--output-partial-info-plist "$PARTIAL" \
	--output-format human-readable-text --errors --warnings --notices 2>&1)"
STATUS=$?
set -e

fail() {
	echo "error: $1" >&2
	echo "------ actool output ------" >&2
	echo "$LOG" >&2
	exit 1
}
[ $STATUS -eq 0 ] || fail "actool exited with status $STATUS"
if echo "$LOG" | grep -q "error:"; then fail "actool reported an error"; fi
echo "$LOG" | grep -q "/Assets\.car$" || fail "actool did not write Assets.car"
echo "$LOG" | grep -q "/$NAME\.icns$" || fail "actool did not write $NAME.icns"
[ -s "$OUT/Assets.car" ] && [ -s "$OUT/$NAME.icns" ] || fail "outputs are missing or empty"

# The catalog must contain the layered icon, not only bitmaps, or macOS 26 has nothing to render as glass.
if ! /usr/bin/assetutil --info "$OUT/Assets.car" | grep -q '"IconImageStack"'; then
	fail "Assets.car has no IconImageStack: the layered Liquid Glass icon was not compiled"
fi
# The partial plist must name the icon the way the bundle's Info.plist will.
for KEY in CFBundleIconName CFBundleIconFile; do
	VALUE="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$PARTIAL" 2>/dev/null || true)"
	[ "$VALUE" = "$NAME" ] || fail "$PARTIAL: expected $KEY = $NAME, found '${VALUE:-nothing}'"
done

WARNINGS="$(echo "$LOG" | grep "warning:" || true)"
if [ -n "$WARNINGS" ]; then
	echo "actool warnings:"
	echo "$WARNINGS"
fi

echo "Compiled $ICON (minimum macOS $MIN) with $ACTOOL"
for F in "$OUT/Assets.car" "$OUT/$NAME.icns"; do
	echo "  $F  $(stat -f %z "$F") bytes  sha256 $(shasum -a 256 "$F" | cut -c1-16)"
done
echo "The bundle needs both files in Contents/Resources and these Info.plist keys:"
echo "  <key>CFBundleIconFile</key><string>$NAME</string>"
echo "  <key>CFBundleIconName</key><string>$NAME</string>"
