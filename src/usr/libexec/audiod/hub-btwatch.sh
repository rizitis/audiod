#!/bin/bash
# audiod hub -- Bluetooth VT-switch watcher.
#
# On a VT switch away from the hub owner, the card handoff cuts the phone's A2DP
# stream mid-buffer and the speakers repeat the last buffer as a loud "tractor"
# drone. This watcher's JOB is to prevent that: when the owner leaves the active
# VT it stops the Bluetooth stream CLEANLY (pause + suspend), so there is no
# drone.
#
# It does NOT auto-reconnect or auto-start music by default -- that starts
# playback on its own, which is usually unwanted. Resume is OPT-IN:
#   HUB_BT_AUTORESUME=yes   reconnect the phone when the owner returns
#   HUB_BT_AUTOPLAY=yes     ...and also send AVRCP play (needs AUTORESUME=yes)
# With both unset (the default) you just get the anti-drone behaviour, and you
# resume manually with 'audioctl hub reconnect' / by pressing play on the phone.
#
# Argument: <owner-uid>

LIB=/usr/libexec/audiod/audiod-lib.sh
HUB=/usr/libexec/audiod/hub.sh
[ -r "$LIB" ] && . "$LIB" 2>/dev/null
type load_config >/dev/null 2>&1 && load_config 2>/dev/null
[ -r "$HUB" ] && . "$HUB" 2>/dev/null

uid="${1:-}"
[ -n "$uid" ] || { echo "hub-btwatch: no uid" >&2; exit 1; }

uname_="$(id -un "$uid" 2>/dev/null)"
seat="${XDG_SEAT:-seat0}"

# uid of the user owning the seat's current ActiveSession
active_uid_of_seat() {
    local sess
    sess=$(loginctl show-seat "$seat" -p ActiveSession --value 2>/dev/null)
    [ -n "$sess" ] || return 1
    loginctl show-session "$sess" -p User --value 2>/dev/null
}

# Owner is leaving the active VT. Stop Bluetooth CLEANLY so the speakers don't
# drone: pause the phone (AVRCP) and suspend the BlueZ input node in PipeWire.
suspend_bt() {
    su - "$uname_" -c 'printf "menu player\npause\n" | bluetoothctl' >/dev/null 2>&1
    su - "$uname_" -c '
        for id in $(pw-cli ls Node 2>/dev/null \
                    | awk "/bluez_input/{print \$2}" | tr -d ,); do
            pw-cli s "$id" suspend 2>/dev/null
        done
        pactl list short sources 2>/dev/null | awk "/bluez/{print \$1}" | \
        while read -r s; do pactl suspend-source "$s" 1 2>/dev/null; done
    ' >/dev/null 2>&1
}

# Owner returned. Only act if the user opted in.
resume_bt() {
    [ "${HUB_BT_AUTORESUME:-no}" = "yes" ] || return 0
    sleep 1
    type hub_bt_reconnect >/dev/null 2>&1 && hub_bt_reconnect "$uid" >/dev/null 2>&1
}

# NOTE: we deliberately do NOTHING at startup -- no reconnect, no play. The box
# should not start music by itself on boot/login.

# Event-driven: watch the seat for ActiveSession changes.
gdbus monitor --system \
    --dest org.freedesktop.login1 \
    --object-path "/org/freedesktop/login1/seat/$seat" 2>/dev/null | \
while read -r line; do
    case "$line" in
        *ActiveSession*)
            if [ "$(active_uid_of_seat)" = "$uid" ]; then
                resume_bt          # opt-in only
            else
                suspend_bt         # always: kill the drone
            fi
            ;;
    esac
done
