#!/bin/bash
# Installs (or updates) the FanPilot root helper as a LaunchDaemon.
#
#   sudo scripts/install_helper.sh [options]
#
# This script builds nothing. It copies an already built fanpilotd, signs it ad hoc, writes the
# launchd plist and the helper config, (re)loads the daemon and checks that its socket appears.
# Running it again is safe: it replaces the binary and plist and reloads the daemon, and it keeps an
# existing helper.json (adding your uid to it if missing).
#
# Options
#   --daemon PATH    fanpilotd to install. Default: <repo>/.build/release/fanpilotd, else the copy
#                    inside <repo>/build/FanPilot.app (scripts/build_app.sh), /Applications/FanPilot.app
#                    or <repo>/FanPilot.app.
#   --ctl PATH       fanpilotctl to install next to it (default: the fanpilotctl beside the daemon).
#   --uid N          uid allowed to talk to the helper (default: the user who ran sudo).
#   --failsafe C     temperature at which the helper forces the fans to maximum (85-100, default 95).
#   --lease SECONDS  longest lease a client may ask for (5-120, default 30).
#   --pin PATH       pin the helper to this app or binary's code signature (repeatable; implies
#                    --reset-config). Ad-hoc signatures change with every rebuild, so reinstall after one.
#   --reset-config   rewrite helper.json instead of keeping the existing file.
#   --stage DIR      TESTING ONLY: install into DIR without root, launchctl or chown.
#   -h, --help       this text.
#
# Recovery if anything ever looks wrong:  sudo fanpilotctl auto all   or   sudo scripts/uninstall_helper.sh

set -euo pipefail

# sudo keeps the caller's PATH; this script runs as root, so it only trusts the system directories.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.fanpilot.helper"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_TEMPLATE="$SCRIPT_DIR/com.fanpilot.helper.plist.template"

DAEMON_SRC=""
CTL_SRC=""
ALLOW_UID=""
FAILSAFE="95"
LEASE="30"
RESET_CONFIG=0
STAGE=""
PINS=()

die() { echo "install_helper: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --daemon)       [ $# -ge 2 ] || die "--daemon needs a path"; DAEMON_SRC="$2"; shift 2 ;;
        --ctl)          [ $# -ge 2 ] || die "--ctl needs a path"; CTL_SRC="$2"; shift 2 ;;
        --uid)          [ $# -ge 2 ] || die "--uid needs a number"; ALLOW_UID="$2"; shift 2 ;;
        --failsafe)     [ $# -ge 2 ] || die "--failsafe needs a number"; FAILSAFE="$2"; shift 2 ;;
        --lease)        [ $# -ge 2 ] || die "--lease needs a number"; LEASE="$2"; shift 2 ;;
        --pin)          [ $# -ge 2 ] || die "--pin needs a path"; PINS+=("$2"); RESET_CONFIG=1; shift 2 ;;
        --reset-config) RESET_CONFIG=1; shift ;;
        --stage)        [ $# -ge 2 ] || die "--stage needs a directory"; STAGE="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown option '$1' (try --help)" ;;
    esac
done

# --- Paths. With --stage everything lives under that directory and nothing privileged happens.
if [ -n "$STAGE" ]; then
    [ -d "$STAGE" ] || die "--stage directory '$STAGE' does not exist"
    STAGE="$(cd "$STAGE" && pwd)"
    echo "*** STAGING into $STAGE: no root, no launchctl, nothing outside that directory is touched ***"
fi
HELPER_DIR="${STAGE}/Library/PrivilegedHelperTools"
DAEMON_DIR="${STAGE}/Library/LaunchDaemons"
SUPPORT_PARENT="${STAGE}/Library/Application Support"
SUPPORT_DIR="${SUPPORT_PARENT}/FanPilot"
HELPER_DEST="${HELPER_DIR}/${LABEL}"
CTL_DEST="${HELPER_DIR}/fanpilotctl"
PLIST_DEST="${DAEMON_DIR}/${LABEL}.plist"
CONFIG="${SUPPORT_DIR}/helper.json"
SOCKET="/var/run/fanpilot.sock"
LOG_PATH="${STAGE}/var/log/fanpilot.log"
LOCAL_BIN="${STAGE}/usr/local/bin"

# --- Validation of the options before anything is touched.
is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_number "$FAILSAFE" && [ "$FAILSAFE" -ge 85 ] && [ "$FAILSAFE" -le 100 ] || die "--failsafe must be a whole number from 85 to 100"
is_number "$LEASE" && [ "$LEASE" -ge 5 ] && [ "$LEASE" -le 120 ] || die "--lease must be a whole number from 5 to 120"
if [ -n "$ALLOW_UID" ]; then
    is_number "$ALLOW_UID" || die "--uid must be a number"
elif [ -n "${SUDO_UID:-}" ] && is_number "$SUDO_UID"; then
    ALLOW_UID="$SUDO_UID"
fi

if [ -z "$STAGE" ]; then
    [ "$(id -u)" -eq 0 ] || die "this script must run as root. Use: sudo $0"
    [ "$(uname -s)" = "Darwin" ] || die "FanPilot only runs on macOS"
fi
[ -f "$PLIST_TEMPLATE" ] || die "missing $PLIST_TEMPLATE"

# --- Locate the binaries.
if [ -z "$DAEMON_SRC" ]; then
    for candidate in "$REPO_DIR/.build/release/fanpilotd" \
                     "/Applications/FanPilot.app/Contents/Resources/helper/fanpilotd" \
                     "$REPO_DIR/build/FanPilot.app/Contents/Resources/helper/fanpilotd" \
                     "$REPO_DIR/FanPilot.app/Contents/Resources/helper/fanpilotd"; do
        if [ -f "$candidate" ]; then DAEMON_SRC="$candidate"; break; fi
    done
fi
[ -n "$DAEMON_SRC" ] || die "no fanpilotd found. Build it first (swift build -c release) or pass --daemon PATH"
[ -f "$DAEMON_SRC" ] && [ -x "$DAEMON_SRC" ] || die "$DAEMON_SRC is not an executable file"
file "$DAEMON_SRC" | grep -q "Mach-O" || die "$DAEMON_SRC is not a Mach-O executable"
if [ -z "$CTL_SRC" ] && [ -f "$(dirname "$DAEMON_SRC")/fanpilotctl" ]; then
    CTL_SRC="$(dirname "$DAEMON_SRC")/fanpilotctl"
fi
if [ -n "$CTL_SRC" ]; then
    [ -f "$CTL_SRC" ] && [ -x "$CTL_SRC" ] || die "$CTL_SRC is not an executable file"
    file "$CTL_SRC" | grep -q "Mach-O" || die "$CTL_SRC is not a Mach-O executable"
fi

# --- The install locations must be root-owned and not writable by anyone else, otherwise a normal
# process could swap the helper or its config. (/Library/Application Support is root:admin 0775 on a
# stock Mac; the FanPilot directory inside it is ours and is checked strictly.)
check_dir() {
    local dir="$1" allow_admin_group="${2:-0}"
    [ -n "$STAGE" ] && return 0
    [ -d "$dir" ] || die "$dir does not exist"
    [ ! -L "$dir" ] || die "$dir is a symbolic link; refusing"
    local owner mode group
    owner="$(stat -f '%u' "$dir")"; mode="$((8#$(stat -f '%Lp' "$dir")))"; group="$(stat -f '%Sg' "$dir")"
    [ "$owner" = "0" ] || die "$dir is not owned by root"
    if (( mode & 8#0002 )); then die "$dir is writable by everyone"; fi
    if (( mode & 8#0020 )); then
        if [ "$allow_admin_group" = "1" ] && [ "$group" = "admin" ]; then
            echo "    note: $dir is writable by the admin group (macOS default); our own subdirectory is protected separately"
        else
            die "$dir is writable by group '$group'"
        fi
    fi
}

as_root() { # chown only when really root (staging runs as a normal user)
    [ -n "$STAGE" ] || chown root:wheel "$@"
}

loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

stop_daemon() {
    [ -z "$STAGE" ] || return 0
    if loaded; then
        info "stopping the running helper (it returns all fans to automatic control first)"
        launchctl bootout "system/${LABEL}" 2>/dev/null || true
        local i
        for i in $(seq 1 30); do loaded || break; sleep 0.5; done
        loaded && die "the helper did not stop within 15 s; check 'launchctl print system/${LABEL}'"
    fi
    # A socket file with nobody behind it would only confuse the next start.
    [ -S "$SOCKET" ] && rm -f "$SOCKET"
    return 0
}

install_binary() { # source destination identifier
    local src="$1" dest="$2" ident="$3" tmp
    tmp="${dest}.new.$$"
    cp -f "$src" "$tmp"
    chmod 0755 "$tmp"
    as_root "$tmp"
    # arm64 refuses unsigned code; ad-hoc is all we have (no Developer ID). Sign after copying: the
    # copy must not depend on the signature of the build directory's file.
    codesign --force --sign - --identifier "$ident" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "codesign failed for $src"; }
    codesign --verify --strict "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "signature check failed for $dest"; }
    mv -f "$tmp" "$dest"
}

cdhash_of() { # path
    local hash
    hash="$(codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
    [ -n "$hash" ] || die "cannot read the code signature of $1 (is it signed? codesign -s - PATH)"
    echo "$hash"
}

# ---------------------------------------------------------------------------------------------
info "checking install locations"
check_dir "${STAGE}/Library"
if [ -n "$STAGE" ]; then
    mkdir -p "$HELPER_DIR" "$DAEMON_DIR" "$SUPPORT_PARENT" "${STAGE}/var/log" "$LOCAL_BIN"
else
    check_dir "$HELPER_DIR"
    check_dir "$DAEMON_DIR"
    check_dir "$SUPPORT_PARENT" 1
fi

stop_daemon

# --- Support directory and config.
info "writing the helper config"
if [ ! -d "$SUPPORT_DIR" ]; then
    mkdir -p "$SUPPORT_DIR"
fi
[ ! -L "$SUPPORT_DIR" ] || die "$SUPPORT_DIR is a symbolic link; refusing"
chmod 0755 "$SUPPORT_DIR"
as_root "$SUPPORT_DIR"
if [ -z "$STAGE" ]; then
    [ "$(stat -f '%u' "$SUPPORT_DIR")" = "0" ] || die "$SUPPORT_DIR is not owned by root"
fi

AUTH_MODE="uid"
PIN_LIST=""
if [ ${#PINS[@]} -gt 0 ]; then
    AUTH_MODE="pinned"
    for pin in "${PINS[@]}"; do
        [ -e "$pin" ] || die "--pin: $pin does not exist"
        hash="$(cdhash_of "$pin")"
        PIN_LIST="${PIN_LIST:+$PIN_LIST, }\"$hash\""
        echo "    pinned $pin -> $hash"
    done
fi

if [ -f "$CONFIG" ] && [ "$RESET_CONFIG" -eq 0 ]; then
    echo "    keeping the existing $CONFIG"
    if [ -n "$ALLOW_UID" ]; then
        if ! plutil -extract allowedUIDs json -o - -- "$CONFIG" 2>/dev/null | grep -Eq "(^|[^0-9])${ALLOW_UID}([^0-9]|$)"; then
            echo "    adding uid $ALLOW_UID to allowedUIDs"
            plutil -insert allowedUIDs -integer "$ALLOW_UID" -append "$CONFIG" 2>/dev/null \
                || die "could not add uid $ALLOW_UID to $CONFIG; edit it by hand or rerun with --reset-config"
        fi
    fi
else
    [ -n "$ALLOW_UID" ] || die "cannot tell which user may control the fans: run through sudo or pass --uid N"
    tmp="$(mktemp "${SUPPORT_DIR}/.helper.json.XXXXXX")"
    {
        printf '{\n'
        printf '  "allowedUIDs" : [%s],\n' "$ALLOW_UID"
        printf '  "authMode" : "%s",\n' "$AUTH_MODE"
        printf '  "failsafeTempC" : %s,\n' "$FAILSAFE"
        printf '  "leaseMaxSeconds" : %s,\n' "$LEASE"
        printf '  "pinnedCdhashes" : [%s],\n' "$PIN_LIST"
        printf '  "socketPath" : "%s"\n' "$SOCKET"
        printf '}\n'
    } > "$tmp"
    chmod 0644 "$tmp"
    as_root "$tmp"
    mv -f "$tmp" "$CONFIG"
    echo "    wrote $CONFIG (uid $ALLOW_UID, failsafe ${FAILSAFE} C, lease max ${LEASE} s, auth $AUTH_MODE)"
fi
plutil -convert xml1 -o /dev/null -- "$CONFIG" 2>/dev/null || die "$CONFIG is not valid JSON"
chmod 0644 "$CONFIG"
as_root "$CONFIG"

# --- Binaries.
info "installing $DAEMON_SRC -> $HELPER_DEST"
install_binary "$DAEMON_SRC" "$HELPER_DEST" "$LABEL"
if [ -n "$CTL_SRC" ]; then
    info "installing $CTL_SRC -> $CTL_DEST"
    install_binary "$CTL_SRC" "$CTL_DEST" "com.fanpilot.ctl"
    # A convenient name on the PATH, but only if that directory cannot be tampered with.
    if [ -d "$LOCAL_BIN" ] && [ ! -L "$LOCAL_BIN" ] \
       && { [ -n "$STAGE" ] || { [ "$(stat -f '%u' "$LOCAL_BIN")" = "0" ] && [ -z "$(find "$LOCAL_BIN" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; }; }; then
        if [ ! -e "$LOCAL_BIN/fanpilotctl" ] || [ -L "$LOCAL_BIN/fanpilotctl" ]; then
            ln -sfn "/Library/PrivilegedHelperTools/fanpilotctl" "$LOCAL_BIN/fanpilotctl"
            echo "    linked $LOCAL_BIN/fanpilotctl"
        else
            echo "    note: $LOCAL_BIN/fanpilotctl already exists and is not a link; not touching it"
        fi
    else
        echo "    note: $LOCAL_BIN is missing or not root-protected; use $CTL_DEST directly"
    fi
else
    echo "    (no fanpilotctl found next to the daemon; recovery then needs scripts/uninstall_helper.sh)"
fi

# --- Log and plist.
mkdir -p "$(dirname "$LOG_PATH")"
[ -f "$LOG_PATH" ] || : > "$LOG_PATH"
# Not world-readable: it records which processes connected (paths of other users' programs). The
# daemon keeps the file bounded itself (it starts over past 8 MiB), so no newsyslog entry is needed.
chmod 0640 "$LOG_PATH"
as_root "$LOG_PATH"
[ -n "$STAGE" ] || chgrp admin "$LOG_PATH"

info "writing $PLIST_DEST"
plist_tmp="$(mktemp "${DAEMON_DIR}/.${LABEL}.plist.XXXXXX")"
sed -e "s|@LABEL@|${LABEL}|g" \
    -e "s|@HELPER_PATH@|/Library/PrivilegedHelperTools/${LABEL}|g" \
    -e "s|@LOG_PATH@|/var/log/fanpilot.log|g" \
    "$PLIST_TEMPLATE" > "$plist_tmp"
plutil -lint "$plist_tmp" >/dev/null || { rm -f "$plist_tmp"; die "the generated plist is invalid"; }
chmod 0644 "$plist_tmp"
as_root "$plist_tmp"
mv -f "$plist_tmp" "$PLIST_DEST"

if [ -n "$STAGE" ]; then
    echo
    echo "Staged install finished under $STAGE (launchctl not touched)."
    exit 0
fi

# --- Load it.
info "starting the helper"
launchctl enable "system/${LABEL}" 2>/dev/null || true
if ! launchctl bootstrap system "$PLIST_DEST"; then
    sleep 1
    launchctl bootstrap system "$PLIST_DEST" || die "launchctl bootstrap failed; see 'launchctl print system/${LABEL}' and /var/log/fanpilot.log"
fi

info "waiting for the socket (the helper scans about 3600 SMC keys at start)"
for i in $(seq 1 60); do
    [ -S "$SOCKET" ] && break
    sleep 0.5
done
if [ ! -S "$SOCKET" ]; then
    echo "--- last lines of /var/log/fanpilot.log ---" >&2
    tail -n 20 /var/log/fanpilot.log >&2 || true
    die "the socket $SOCKET did not appear"
fi
mode="$(stat -f '%Lp' "$SOCKET")"; owner="$(stat -f '%u' "$SOCKET")"
[ "$owner" = "0" ] || die "$SOCKET is not owned by root"
[ "$mode" = "666" ] || echo "    warning: $SOCKET has mode $mode (expected 666)"

if [ -x "$CTL_DEST" ]; then
    "$CTL_DEST" daemon-ping || echo "    warning: the helper is up but did not answer daemon-ping"
fi

cat <<EOF

FanPilot helper installed and running.
  binary   $HELPER_DEST
  config   $CONFIG
  log      /var/log/fanpilot.log
  socket   $SOCKET

Check it:     fanpilotctl status
Recovery:     sudo fanpilotctl auto all        (returns every fan to automatic control)
Uninstall:    sudo $SCRIPT_DIR/uninstall_helper.sh
EOF
