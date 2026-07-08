#!/bin/bash
# audiod hub -- Bluetooth auto-reconnect watcher.
#
# The problem: on a VT switch away from the hub owner, the card handoff drops
# the owner's Bluetooth audio (the phone shows Connected: no, or its A2DP stream
# is gone). Plain speaker audio comes back on its own when the owner is active
# again, but Bluetooth does not re-establish by itself.
#
# This watcher listens to elogind for active-session changes on the seat and,
# whenever the HUB OWNER becomes the active session again, reconnects their
# paired Bluetooth device(s). It runs as the owner (started by the reactor via
# daemon(1)) so bluetoothctl talks to the right session.
#
# Argument: <owner-uid>

LIB=/usr/libexec/audiod/audiod-lib.sh
HUB=/usr/libexec/audiod/hub.sh
[ -r "$LIB" ] && . "$LIB" 2>/dev/null
type load_config >/dev/null 2>&1 && load_config 2>/dev/null
[ -r "$HUB" ] && . "$HUB" 2>/dev/null

uid="${1:-}"
[ -n "$uid" ] || { echo "hub-btwatch: no uid" >&2; exit 1; }

seat="${XDG_SEAT:-seat0}"

# uid of the user owning the seat's current ActiveSession
active_uid_of_seat() {
    local sess
    sess=$(loginctl show-seat "$seat" -p ActiveSession --value 2>/dev/null)
    [ -n "$sess" ] || return 1
    loginctl show-session "$sess" -p User --value 2>/dev/null
}

reconnect_now() {
    # small settle so uaccess ACLs and the card are back before we reconnect
    sleep 1
    if type hub_bt_reconnect >/dev/null 2>&1; then
        hub_bt_reconnect "$uid" >/dev/null 2>&1
    fi
}

# Owner is leaving (VT switch away). The A2DP stream is about to be cut when the
# card handoff happens; if we let it be cut mid-buffer the speakers repeat the
# last buffer as a loud "tractor" drone. So we stop it CLEANLY first: pause the
# phone over AVRCP and suspend the BlueZ input node, so no garbage is left.
suspend_bt() {
    # pause the source (phone) so it stops sending, via AVRCP
    su - "$(id -un "$uid" 2>/dev/null)" -c \
        'printf "menu player\npause\n" | bluetoothctl' >/dev/null 2>&1
    # suspend the bluez input node in PipeWire so the buffer is flushed cleanly
    su - "$(id -un "$uid" 2>/dev/null)" -c '
        for id in $(pw-cli ls Node 2>/dev/null \
                    | awk "/bluez_input/{print \$2}" | tr -d ,); do
            pw-cli s "$id" suspend 2>/dev/null
        done
    ' >/dev/null 2>&1
    # as a fallback, drop the ALSA/BT link by muting the bluez input stream
    su - "$(id -un "$uid" 2>/dev/null)" -c '
        pactl list short sources 2>/dev/null | awk "/bluez/{print \$1}" | \
        while read -r s; do pactl suspend-source "$s" 1 2>/dev/null; done
    ' >/dev/null 2>&1
}

# Reconnect once at startup in case we were (re)started while already active.
if [ "$(active_uid_of_seat)" = "$uid" ]; then
    reconnect_now
fi

# Event-driven: watch the seat object for ActiveSession property changes.
gdbus monitor --system \
    --dest org.freedesktop.login1 \
    --object-path "/org/freedesktop/login1/seat/$seat" 2>/dev/null | \
while read -r line; do
    case "$line" in
        *ActiveSession*)
            # the active session on this seat changed
            if [ "$(active_uid_of_seat)" = "$uid" ]; then
                # owner is active again -> reconnect + resume BT
                reconnect_now
            else
                # owner just lost the seat -> stop BT cleanly (no tractor drone)
                suspend_bt
            fi
            ;;
    esac
done
