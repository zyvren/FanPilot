#!/bin/bash
# Packages build/FanPilot.app into a drag-to-install disk image: dist/FanPilot-<version>.dmg
#
#   scripts/make_dmg.sh [--build] [--no-layout]
#
#   --build       run scripts/build_app.sh first (otherwise the existing build/FanPilot.app is used)
#   --no-layout   skip the Finder window layout (background, icon positions); for headless machines
#
# The mounted volume shows assets/dmg-background.png as its window background, with FanPilot.app and
# an Applications shortcut placed in the empty right-hand side of the artwork. The layout is applied
# by Finder through AppleScript (the same approach create-dmg uses), so the first run may ask to let
# Terminal control Finder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/build/FanPilot.app"
BACKGROUND="$ROOT/assets/dmg-background.png"
VOLUME_NAME="FanPilot"

# Window content size in points; the background is rendered at this size and at 2x for Retina.
WINDOW_W=768
WINDOW_H=512
ICON_SIZE=112
# Finder sizes the scrollable area from each item's full cell (icon plus label, roughly 100 pt either
# side of the centre at this icon size), not the icon alone. Keep every cell well inside the window,
# or Finder adds a horizontal scroll bar and opens the window scrolled.
APP_X=410
APPS_X=620
ICON_Y=250
APP_POS="$APP_X, $ICON_Y"
APPS_POS="$APPS_X, $ICON_Y"
# The arrow runs between the two icons, leaving a little air on each side.
ARROW_FROM=$((APP_X + ICON_SIZE / 2 + 14))
ARROW_TO=$((APPS_X - ICON_SIZE / 2 - 14))

die() { echo "make_dmg: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

DO_BUILD=0
DO_LAYOUT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --build)     DO_BUILD=1; shift ;;
        --no-layout) DO_LAYOUT=0; shift ;;
        -h|--help)   sed -n '2,13p' "$0"; exit 0 ;;
        *)           die "unknown option: $1" ;;
    esac
done

[ "$DO_BUILD" -eq 1 ] && "$SCRIPT_DIR/build_app.sh"
[ -d "$APP" ] || die "$APP not found; run scripts/build_app.sh (or pass --build)"
[ -f "$BACKGROUND" ] || die "$BACKGROUND not found"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
FINAL="$DIST/FanPilot-$VERSION.dmg"
mkdir -p "$DIST"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanpilot-dmg.XXXXXX")"
MOUNT_DIR=""
cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- 1. Staging folder: the app, an Applications shortcut, the hidden background.
info "staging the volume contents"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/FanPilot.app"
ln -s /Applications "$STAGE/Applications"

# The artwork scaled to the window, with an arrow from the app to Applications, at 1x and 2x.
for SCALE in 1 2; do
    OUT="$WORK/background.png"
    [ "$SCALE" -eq 2 ] && OUT="$WORK/background@2x.png"
    swift "$SCRIPT_DIR/dmg_background.swift" "$BACKGROUND" "$OUT" "$WINDOW_W" "$WINDOW_H" "$SCALE" \
        "$ARROW_FROM" "$ARROW_TO" "$((ICON_Y - 6))" || die "could not render the background"
done
# One multi-resolution TIFF: Finder picks the 2x page on Retina displays.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1


# --- 2. Writable image, so Finder can store the window layout in the volume's .DS_Store.
info "creating a writable image"
RW="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_MB}m" "$RW"

# A volume of the same name already mounted would make Finder lay out the wrong window.
if [ -d "/Volumes/$VOLUME_NAME" ]; then
    die "a volume named $VOLUME_NAME is already mounted; eject it and run again"
fi
MOUNT_DIR="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen \
    | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
[ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ] || die "could not mount the writable image"

# --- 3. Finder layout.
if [ "$DO_LAYOUT" -eq 1 ]; then
    info "laying out the Finder window"
    DISK_NAME="$(basename "$MOUNT_DIR")"
    # Finder window bounds include the title bar, so add its height to the content height. Its height
    # changed across macOS releases (28 pt before macOS 26, 32 pt since); if the content area ends up
    # even a few points shorter than the background, Finder adds a scroll bar. Measure it here.
    TITLEBAR="$(swift -e 'import AppKit
let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
let frame = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: style)
print(Int((frame.height - 100).rounded(.up)))' 2>/dev/null || true)"
    case "$TITLEBAR" in ''|*[!0-9]*) TITLEBAR=32 ;; esac
    osascript <<EOF
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + WINDOW_W)), $((120 + WINDOW_H + TITLEBAR))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "FanPilot.app" of container window to {$APP_POS}
        set position of item "Applications" of container window to {$APPS_POS}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
    # Give Finder time to flush .DS_Store before the volume is unmounted.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$MOUNT_DIR/.DS_Store" ] && break
        sleep 1
    done
    [ -f "$MOUNT_DIR/.DS_Store" ] || echo "    warning: Finder did not write the layout (.DS_Store)" >&2
fi

# Volume icon = the app icon. Copied last, after Finder has laid out the
# window (it did not survive Finder's pass when copied earlier), then the volume root is flagged as
# having a custom icon.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$MOUNT_DIR"
    else
        echo "    warning: SetFile not found; the volume keeps the default disk icon" >&2
    fi
fi

rm -rf "$MOUNT_DIR/.fseventsd" 2>/dev/null || true   # Spotlight/fsevents bookkeeping, not content
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
MOUNT_DIR=""

# --- 4. Compressed, read-only final image.
info "compressing"
rm -f "$FINAL"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL"
hdiutil verify -quiet "$FINAL"

info "built $FINAL ($(du -h "$FINAL" | cut -f1 | tr -d ' '))"
