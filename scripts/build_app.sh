#!/bin/bash
# Builds FanPilot.app.
#
#   scripts/build_app.sh [--skip-build] [--no-icon]
#
# Steps: swift build -c release (app, helper daemon, CLI) -> assemble build/FanPilot.app -> ad-hoc
# codesign every Mach-O (inner binaries first, then the bundle). There is no Developer ID; an ad-hoc
# signature is enough for a locally built app to launch.
#
#   --skip-build  reuse the products of the last release build
#   --no-icon     do not generate the app icon
#
# The helper (fanpilotd, fanpilotctl and the install scripts) is bundled in
# FanPilot.app/Contents/Resources/helper. The app installs it on request, with an administrator
# password prompt. Nothing here needs root and nothing here touches the fans.
#
# The release build lives in .build/release-app (its own scratch path, so it never collides with the
# debug builds other people run).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRATCH="$ROOT/.build/release-app"
OUT="$ROOT/build"
APP="$OUT/FanPilot.app"
VERSION="1.0"
SKIP_BUILD=0
MAKE_ICON=1

die() { echo "build_app: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --no-icon)    MAKE_ICON=0; shift ;;
        -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown option '$1' (try --help)" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "FanPilot builds on macOS only"
cd "$ROOT"

# --- 1. Compile.
if [ "$SKIP_BUILD" -eq 0 ]; then
    info "swift build -c release"
    # One invocation per product: with several --product flags the build system only honors the last.
    for product in FanPilotApp fanpilotd fanpilotctl; do
        swift build -c release --scratch-path "$SCRATCH" --product "$product"
    done
fi
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"
for product in FanPilotApp fanpilotd fanpilotctl; do
    [ -x "$BIN_DIR/$product" ] || die "missing $BIN_DIR/$product (run without --skip-build)"
done

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# --- 2. Assemble the bundle.
info "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"

cp "$BIN_DIR/FanPilotApp" "$APP/Contents/MacOS/FanPilot"

HELPER_DIR="$APP/Contents/Resources/helper"
cp "$BIN_DIR/fanpilotd" "$BIN_DIR/fanpilotctl" "$HELPER_DIR/"
cp "$SCRIPT_DIR/install_helper.sh" "$SCRIPT_DIR/uninstall_helper.sh" \
   "$SCRIPT_DIR/com.fanpilot.helper.plist.template" "$HELPER_DIR/"
chmod 0755 "$HELPER_DIR/install_helper.sh" "$HELPER_DIR/uninstall_helper.sh" \
           "$HELPER_DIR/fanpilotd" "$HELPER_DIR/fanpilotctl"

sed -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD_NUMBER|g" \
    "$SCRIPT_DIR/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist is invalid"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- 3. Icon (optional: a missing icon must not stop the build).
if [ "$MAKE_ICON" -eq 1 ]; then
    info "generating the app icon"
    ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fanpilot-icon.XXXXXX")"
    LOGO="$ROOT/assets/logo-FanPilot.png"
    LOGO_ARGS=()
    [ -f "$LOGO" ] && LOGO_ARGS=("$LOGO")
    if swift "$SCRIPT_DIR/make_icon.swift" "$ICON_TMP/AppIcon.iconset" ${LOGO_ARGS[@]+"${LOGO_ARGS[@]}"} \
       && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
        :
    else
        echo "    warning: could not generate the icon; the app will use the generic one" >&2
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
    fi
    rm -rf "$ICON_TMP"
else
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# --- 4. Sign: inner binaries first, then the executable, then the bundle (which seals the rest).
# Extended attributes (quarantine, Finder info) must be gone before signing or codesign refuses.
xattr -cr "$APP" 2>/dev/null || true
info "ad-hoc code signing"
codesign --force --sign - --identifier com.fanpilot.helper "$HELPER_DIR/fanpilotd"
codesign --force --sign - --identifier com.fanpilot.ctl "$HELPER_DIR/fanpilotctl"
codesign --force --sign - --identifier com.fanpilot.app "$APP/Contents/MacOS/FanPilot"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

info "built $APP (version $VERSION, build $BUILD_NUMBER)"
echo "$APP"
