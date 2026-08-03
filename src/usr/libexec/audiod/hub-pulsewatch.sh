#!/bin/bash
# hub-pulsewatch.sh <uid>
#
# Restore the hub's pulse-side objects after pipewire-pulse is replaced.
#
# WHY THIS EXISTS
# ---------------
# 'hub_combined' and the network-audio module are loaded INTO pipewire-pulse
# with pactl. They live inside that process: when pipewire-pulse exits, they
# die with it. audiod's supervisor then restarts the service, so the stack
# looks perfectly healthy afterwards -- pipewire, wireplumber and
# pipewire-pulse all 'running', audio working -- while the hub is silently and
# permanently gone.
#
# Nothing put it back, because hub_start only runs on a login1 UserNew signal.
# A service restart is not a login, so the hub stayed missing until the next
# real logout/login, and the daemon had no idea anything was wrong.
#
# This watcher closes that gap: it notices the pulse server has been replaced
# and re-applies the owner's extras. It is idempotent -- hub_net_init and
# hub_combine_init both no-op when their object already exists -- so a spurious
# wakeup costs one cheap query and nothing else.
#
# It deliberately does NOT recreate anything the user turned off by hand:
# 'audioctl hub combine off' records the intent, and this respects it.
#
# Runs as the owner. Started by hub_btwatch_start's sibling, hub_pulsewatch_start.

uid="${1:-$(id -u)}"

LIB=/usr/libexec/audiod/audiod-lib.sh
HUB=/usr/libexec/audiod/hub.sh
[ -r "$LIB" ] || exit 0
[ -r "$HUB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB"
load_config
# shellcheck source=/dev/null
. "$HUB"

INTERVAL="${HUB_PULSEWATCH_INTERVAL:-5}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
[ "$INTERVAL" -lt 2 ] && INTERVAL=2

# Identity of the running pulse server. When this changes, the server was
# replaced and everything we loaded into it is gone. The pipewire-pulse pid is
# the cheapest reliable marker; fall back to the pulse socket's inode so the
# watcher still works if pgrep is unavailable.
pulse_ident() {
    local p
    p=$(pgrep -u "$uid" -x pipewire-pulse 2>/dev/null | head -1)
    if [ -n "$p" ]; then
        echo "pid:$p"
        return
    fi
    local sock="/run/user/$uid/pulse/native"
    if [ -S "$sock" ]; then
        echo "ino:$(stat -c %i "$sock" 2>/dev/null)"
        return
    fi
    echo "none"
}

last=$(pulse_ident)

while :; do
    sleep "$INTERVAL"

    now=$(pulse_ident)
    [ "$now" = "none" ] && continue          # server down; nothing to do yet

    if [ "$now" != "$last" ]; then
        log "hub: pipewire-pulse was replaced ($last -> $now); restoring hub extras"
        last="$now"
        # The new server needs a moment before it can answer, and wireplumber
        # needs longer still to republish the card. Both gates handle that.
        hub_net_init "$uid"
        if hub_combine_wanted "$uid"; then
            hub_combine_init "$uid"
        else
            dbg "hub: combine is switched off by the user; not restoring it"
        fi
        continue
    fi

    # Same server, but the combine sink can also vanish on its own (e.g. every
    # member sink disappeared and came back). Re-assert it cheaply.
    if [ "${COMBINE:-no}" = "yes" ] && hub_combine_wanted "$uid"; then
        if [ -z "$(hub_combined_id "$uid")" ]; then
            log "hub: 'hub_combined' disappeared without a server restart; recreating"
            hub_combine_init "$uid"
        fi
    fi
done
