#!/bin/bash
# Removes the FanPilot root helper.
#
#   sudo scripts/uninstall_helper.sh [--purge] [--stage DIR]
#
# Stopping the daemon makes it return every fan to automatic control (it handles SIGTERM). As a
# second line of defense the script then runs 'fanpilotctl auto all --direct' itself, which writes
# the fan mode keys without the daemon, and checks the result. Files are removed only if that check
# passed. If it did not (or the daemon could not be stopped and there is no way to check), NOTHING is
# removed, the script says so and exits non-zero: fanpilotctl is the recovery tool, so it stays.
#
# Options
#   --purge       also delete the config directory and the log file (otherwise they are kept, so a
#                 later install picks up your helper.json again).
#   --stage DIR   TESTING ONLY: operate on DIR instead of the real system; no root, no launchctl.
#   -h, --help    this text.
#
# Safe to run when nothing is installed, and safe to run twice.

set -euo pipefail

# sudo keeps the caller's PATH; this script runs as root, so it only trusts the system directories.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.fanpilot.helper"
PURGE=0
STAGE=""

die() { echo "uninstall_helper: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        --stage) [ $# -ge 2 ] || die "--stage needs a directory"; STAGE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

if [ -n "$STAGE" ]; then
    [ -d "$STAGE" ] || die "--stage directory '$STAGE' does not exist"
    STAGE="$(cd "$STAGE" && pwd)"
    echo "*** STAGING on $STAGE: no root, no launchctl, nothing outside that directory is touched ***"
else
    [ "$(id -u)" -eq 0 ] || die "this script must run as root. Use: sudo $0"
    [ "$(uname -s)" = "Darwin" ] || die "FanPilot only runs on macOS"
fi

HELPER_DEST="${STAGE}/Library/PrivilegedHelperTools/${LABEL}"
CTL_DEST="${STAGE}/Library/PrivilegedHelperTools/fanpilotctl"
CTL_LINK="${STAGE}/usr/local/bin/fanpilotctl"
PLIST_DEST="${STAGE}/Library/LaunchDaemons/${LABEL}.plist"
SUPPORT_DIR="${STAGE}/Library/Application Support/FanPilot"
LOG_PATH="${STAGE}/var/log/fanpilot.log"
SOCKET="/var/run/fanpilot.sock"

loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

# --- 1. Stop the daemon. launchd sends SIGTERM; the daemon releases the fans and exits.
STILL_LOADED=0
if [ -z "$STAGE" ]; then
    if loaded; then
        info "stopping the helper (it returns all fans to automatic control first)"
        launchctl bootout "system/${LABEL}" 2>/dev/null || true
        for i in $(seq 1 30); do loaded || break; sleep 0.5; done
        if loaded; then
            echo "    the helper did not stop in 15 s; killing it"
            pid="$(launchctl print "system/${LABEL}" 2>/dev/null | sed -n 's/^[[:space:]]*pid = //p' | head -n 1)"
            [ -z "$pid" ] || kill -9 "$pid" 2>/dev/null || true
            launchctl bootout "system/${LABEL}" 2>/dev/null || true
            sleep 1
            if loaded; then STILL_LOADED=1; fi
        fi
    else
        info "the helper is not loaded"
    fi
    [ -S "$SOCKET" ] && rm -f "$SOCKET"
fi

# --- 2. Make sure no fan is left in manual mode, whatever happened above.
# Only our own installed copy is run as root. (/usr/local/bin/fanpilotctl is just a link to it, and
# that directory can be user-writable on some Macs, so it is never executed from here.)
trusted_ctl() {
    [ -f "$CTL_DEST" ] && [ -x "$CTL_DEST" ] && [ ! -L "$CTL_DEST" ] || return 1
    [ "$(stat -f '%u' "$CTL_DEST")" = "0" ] || return 1
    [ -z "$(find "$CTL_DEST" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ] || return 1
}

UNSAFE=0
if [ -z "$STAGE" ]; then
    if trusted_ctl; then
        info "checking that every fan is back under system control"
        if ! "$CTL_DEST" auto all --direct; then
            UNSAFE=1
            echo "    ERROR: fanpilotctl could not confirm that all fans are in automatic mode." >&2
        fi
    elif [ -e "$CTL_DEST" ]; then
        UNSAFE=1
        echo "    ERROR: $CTL_DEST is not a root-owned, non-writable executable; not running it as root." >&2
    else
        echo "    note: fanpilotctl is not installed, so the fan state could not be double-checked."
        echo "    The helper itself returns the fans to automatic control when it stops; a restart also resets them."
    fi
    if [ "$STILL_LOADED" -eq 1 ] && [ "$UNSAFE" -eq 0 ] && ! trusted_ctl; then
        UNSAFE=1
        echo "    ERROR: the helper is still loaded and there is no fanpilotctl to confirm the fans." >&2
    fi
    if [ "$UNSAFE" -eq 1 ]; then
        echo >&2
        echo "NOT REMOVING ANYTHING: the fans may still be under manual control, and fanpilotctl is the tool that fixes that." >&2
        echo "    Try again:   sudo $CTL_DEST auto all" >&2
        echo "    Or restart the Mac (the SMC returns the fans to automatic control at boot)," >&2
        echo "    then run this script again." >&2
        exit 1
    fi
fi

# --- 3. Remove what we installed (explicit paths only).
info "removing files"
rm -f "$PLIST_DEST" "$HELPER_DEST" "$CTL_DEST"
if [ -L "$CTL_LINK" ]; then
    # Only our own link: it must point at the installed fanpilotctl.
    case "$(readlink "$CTL_LINK")" in
        /Library/PrivilegedHelperTools/fanpilotctl) rm -f "$CTL_LINK" ;;
        *) echo "    leaving $CTL_LINK alone (it is not our link)" ;;
    esac
fi
if [ "$PURGE" -eq 1 ]; then
    rm -f "$SUPPORT_DIR/helper.json"
    rmdir "$SUPPORT_DIR" 2>/dev/null || echo "    note: $SUPPORT_DIR contains other files and was left in place"
    rm -f "$LOG_PATH"
    echo "    removed the config and the log"
else
    [ ! -d "$SUPPORT_DIR" ] || echo "    kept $SUPPORT_DIR and $LOG_PATH (use --purge to delete them)"
fi

echo
echo "FanPilot helper removed. The fans are under system control."
