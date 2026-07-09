#!/bin/bash
# audiod hub extension -- turn the host into a party audio hub.
#
# Sourced by audiod ONLY when HUB_MODE=yes in audiod.conf. When HUB_MODE=no
# (the default) NONE of this runs and audiod behaves exactly as build 7.
#
# What "hub" adds, on top of the normal per-user PipeWire stack:
#   * BT_SINK   : phones/laptops pair with this box and play THROUGH it
#                 (the box is a Bluetooth speaker). Pairing requires the
#                 normal BlueZ agent -- NO blind auto-accept.
#   * NET_TCP   : trusted machines on the LAN can send audio to this box over
#                 TCP, restricted to an explicit allow-list of addresses.
#   * COMBINE   : mirror playback to several outputs at once (e.g. built-in
#                 speakers + a BT speaker) via a combine-sink.
#
# SECURITY POSTURE (deliberately conservative):
#   * Bluetooth is made pairable/discoverable only for a SHORT, bounded window
#     that you trigger on purpose (hub_bt_pairing_window), NOT permanently.
#   * Pairing still goes through BlueZ; a PIN/confirmation is required unless
#     the admin has configured the adapter otherwise. We never install a
#     "just-works, accept-everything" agent.
#   * Network audio is OFF unless NET_TCP=yes AND you list explicit allowed
#     addresses in NET_ACL. We never bind to 0.0.0.0 implicitly.
#   * Everything here is best-effort and logged; failures never break the core
#     audio stack.
#
# This file manages a USER PipeWire (the hub user). It does NOT start or
# configure system services: bluetoothd must already be running and the
# adapter powered (that is a system/rc.d concern, not audiod's).

# ---- helpers ---------------------------------------------------------------

hub_enabled() { [ "${HUB_MODE:-no}" = "yes" ]; }

# Is <uid> allowed to use the hub? Membership in HUB_GROUP (default audiohub).
# The hub runs per-user for every logged-in member of that group; users outside
# it are ignored entirely, so hub mode never touches non-members' sessions.
hub_user_allowed() {            # hub_user_allowed <uid>
    local uid="$1" grp="${HUB_GROUP:-audiohub}" uname
    uname=$(id -un "$uid" 2>/dev/null) || return 1
    # group must exist; if it doesn't, nobody is allowed (safe default)
    getent group "$grp" >/dev/null 2>&1 || return 1
    id -nG "$uname" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"
}

# run wpctl/pactl/bluetoothctl as the hub user with its PipeWire environment
hub_as_user() {                 # hub_as_user <uid> <cmd...>
    local uid="$1"; shift
    run_as_user "$uid" "$@"
}

hub_have() {                    # hub_have <cmd>  -- is a binary available?
    command -v "$1" >/dev/null 2>&1
}

# ---- Bluetooth sink (phones play THROUGH this box) -------------------------
#
# We do NOT force the adapter discoverable forever. Instead we expose a bounded
# pairing window that the operator triggers. Outside that window the box is not
# advertising, which is the safe default for a party box in a public space.

hub_bt_available() {
    hub_have bluetoothctl || { log "hub: bluetoothctl not found; BT sink disabled"; return 1; }
    # bluetoothd must be up and an adapter present
    if ! bluetoothctl show >/dev/null 2>&1; then
        log "hub: no Bluetooth adapter / bluetoothd not running; BT sink disabled"
        return 1
    fi
    return 0
}

# Open a bounded pairing window (default 120s). Requires a real pairing
# handshake on the phone side; we do NOT auto-trust unknown devices.
hub_bt_pairing_window() {       # hub_bt_pairing_window <uid> [seconds]
    local uid="$1" secs="${2:-${BT_PAIR_SECONDS:-120}}"
    hub_bt_available || return 1

    log "hub: opening Bluetooth pairing window for ${secs}s"
    # Power on, make pairable + discoverable for the window only.
    hub_as_user "$uid" bluetoothctl -- power on           >/dev/null 2>&1
    hub_as_user "$uid" bluetoothctl -- pairable on         >/dev/null 2>&1
    hub_as_user "$uid" bluetoothctl -- discoverable-timeout "$secs" >/dev/null 2>&1
    hub_as_user "$uid" bluetoothctl -- discoverable on     >/dev/null 2>&1

    # Close the window after the timeout (background, non-blocking). BlueZ also
    # auto-clears discoverable via discoverable-timeout; this is belt-and-braces.
    (
        sleep "$secs"
        hub_as_user "$uid" bluetoothctl -- discoverable off >/dev/null 2>&1
        hub_as_user "$uid" bluetoothctl -- pairable off     >/dev/null 2>&1
        log "hub: Bluetooth pairing window closed"
    ) </dev/null >/dev/null 2>&1 &
}

# On hub start we DO NOT open the window automatically (safe default). We just
# make sure the adapter is powered so already-paired phones can reconnect.
hub_bt_init() {                 # hub_bt_init <uid>
    hub_bt_available || return 0
    hub_as_user "$uid" bluetoothctl -- power on >/dev/null 2>&1
    log "hub: Bluetooth ready; paired devices may reconnect. Run"
    log "hub:   audioctl hub pair        (to open a pairing window on demand)"
}

# Reconnect all trusted/paired audio devices to THIS user's PipeWire. Used to
# recover after another user's login stole the shared BT device (the conflict
# we hit in testing): the owner runs this and the phone comes back to them.
hub_bt_reconnect() {            # hub_bt_reconnect <uid>
    hub_bt_available || return 1
    hub_as_user "$uid" bluetoothctl -- power on >/dev/null 2>&1
    local mac cnt=0
    # reconnect every paired device (phones); harmless for non-audio ones
    while read -r _ mac _; do
        [ -n "$mac" ] || continue
        # trust so BlueZ will also auto-reconnect it on its own in future
        hub_as_user "$uid" bluetoothctl -- trust "$mac"   >/dev/null 2>&1
        hub_as_user "$uid" bluetoothctl -- connect "$mac" >/dev/null 2>&1 && cnt=$((cnt+1))
    done < <(hub_as_user "$uid" bluetoothctl -- devices Paired 2>/dev/null \
             || hub_as_user "$uid" bluetoothctl -- devices 2>/dev/null)

    # Optionally ask the phone to resume playback. OFF by default so the box
    # never starts music on its own; set HUB_BT_AUTOPLAY=yes to enable.
    if [ "$cnt" -gt 0 ] && [ "${HUB_BT_AUTOPLAY:-no}" = "yes" ]; then
        sleep 1
        hub_as_user "$uid" sh -c 'printf "menu player\nplay\n" | bluetoothctl' \
            >/dev/null 2>&1
    fi

    log "hub: reconnected $cnt Bluetooth device(s) to uid $uid"
    [ "$cnt" -gt 0 ]
}

# ---- interactive scan + connect (from the terminal) ------------------------
#
# Discover nearby Bluetooth devices (speakers AND phones), show a numbered list,
# let the user pick one by number, and connect it -- so you don't need the
# desktop's Bluetooth menu. Runs as the given uid so bluetoothctl uses the right
# session.
hub_scan_connect() {            # hub_scan_connect <uid> [scan_seconds]
    hub_bt_available || { echo "Bluetooth adapter not available."; return 1; }
    local uid="$1" secs="${2:-8}"

    hub_as_user "$uid" bluetoothctl -- power on >/dev/null 2>&1

    echo "Scanning for ${secs}s..."
    # timed scan; bluetoothctl populates the device cache while it runs
    hub_as_user "$uid" sh -c "bluetoothctl --timeout $secs scan on >/dev/null 2>&1"

    # collect devices: lines look like 'Device <MAC> <name...>'
    local macs=() names=() mac name
    while read -r _ mac name; do
        [ -n "$mac" ] || continue
        case "$mac" in [0-9A-Fa-f][0-9A-Fa-f]:*) ;; *) continue ;; esac
        macs+=("$mac"); names+=("${name:-$mac}")
    done < <(hub_as_user "$uid" bluetoothctl -- devices 2>/dev/null)

    if [ "${#macs[@]}" -eq 0 ]; then
        echo "No devices found. Put the target in pairing/discoverable mode and retry."
        return 1
    fi

    echo ""
    echo "Found devices:"
    local i info state
    for i in "${!macs[@]}"; do
        # figure out this device's state for a helpful label
        info=$(hub_as_user "$uid" bluetoothctl -- info "${macs[$i]}" 2>/dev/null)
        if printf '%s' "$info" | grep -q 'Connected: yes'; then
            state="connected"
        elif printf '%s' "$info" | grep -q 'Paired: yes'; then
            state="paired"
        else
            state="new"
        fi
        printf "  %2d) %-24s [%s]  (%s)\n" \
            "$((i+1))" "${names[$i]}" "${macs[$i]}" "$state"
    done
    echo ""
    printf "Connect which number (Enter to cancel)? "
    local choice; read -r choice
    [ -n "$choice" ] || { echo "Cancelled."; return 0; }
    case "$choice" in *[!0-9]*|'') echo "Not a number."; return 1 ;; esac
    local idx=$((choice-1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#macs[@]}" ]; then
        echo "Out of range."; return 1
    fi

    local target="${macs[$idx]}" tname="${names[$idx]}"
    # if it's already connected, offer to disconnect instead (toggle)
    if hub_as_user "$uid" bluetoothctl -- info "$target" 2>/dev/null \
        | grep -q 'Connected: yes'; then
        printf "%s is already connected. Disconnect it? (type 'yes') " "$tname"
        local yn; read -r yn
        case "$yn" in
            yes|YES|Yes)
                if hub_as_user "$uid" bluetoothctl -- disconnect "$target" >/dev/null 2>&1; then
                    echo "Disconnected: $tname"
                else
                    echo "Could not disconnect $tname."
                    return 1
                fi
                ;;
            *) echo "Left connected." ;;
        esac
        return 0
    fi

    echo "Connecting to $tname [$target] ..."
    hub_as_user "$uid" bluetoothctl -- pair    "$target" >/dev/null 2>&1
    hub_as_user "$uid" bluetoothctl -- trust   "$target" >/dev/null 2>&1
    if hub_as_user "$uid" bluetoothctl -- connect "$target" >/dev/null 2>&1; then
        echo "Connected: $tname"
    else
        echo "Could not connect. If it needs a PIN, run 'audioctl hub pair' first."
        return 1
    fi
}

# ---- BT auto-reconnect watcher (VT-switch-back recovery) -------------------
#
# Starts a per-owner background watcher (via daemon(1)) that reconnects the
# owner's Bluetooth whenever they become the active session again. This is what
# makes BT "survive" VT switches without the user running anything.

HUB_BTWATCH=/usr/libexec/audiod/hub-btwatch.sh

hub_btwatch_start() {           # hub_btwatch_start <uid>
    local uid="$1"
    [ -x "$HUB_BTWATCH" ] || return 0
    # absolute pidfile dir (XDG runtime); '~' does not expand reliably under sh -c
    local rundir="/run/user/$uid"
    # already running? (check by pidfile, and by process, to avoid duplicates)
    if hub_as_user "$uid" sh -c \
        "daemon --pidfiles='$rundir' --name=hub-btwatch --running" 2>/dev/null; then
        dbg "hub: btwatch already running for uid $uid"
        return 0
    fi
    # belt-and-braces: if a stray copy is already running, don't start another
    if pgrep -u "$uid" -f "hub-btwatch.sh $uid" >/dev/null 2>&1; then
        dbg "hub: btwatch process already present for uid $uid"
        return 0
    fi
    hub_as_user "$uid" sh -c \
        "daemon -rB --pidfiles='$rundir' --name=hub-btwatch -- '$HUB_BTWATCH' $uid" \
        2>/dev/null
    log "hub: started Bluetooth VT-switch watcher for uid $uid"
}

hub_btwatch_stop() {            # hub_btwatch_stop <uid>
    local uid="$1"
    local rundir="/run/user/$uid"
    hub_as_user "$uid" sh -c \
        "daemon --pidfiles='$rundir' --name=hub-btwatch --stop" 2>/dev/null
    # clean up any stray copy that escaped the supervisor
    pkill -u "$uid" -f "hub-btwatch.sh $uid" 2>/dev/null
    return 0
}

# ---- who owns the hub (card + Bluetooth) -----------------------------------
#
# The card and the single system-wide BT adapter can only be held by ONE user's
# PipeWire at a time. When a second hub member logs in on another seat/VT, their
# WirePlumber would otherwise grab the shared BT device and cut the owner off
# (observed in testing). So only the OWNER runs the BT/card side; other members
# are kept from fighting for the device.
#
# Ownership is decided automatically: the FIRST hub member to log in claims it
# (recorded in a /run state file that clears on reboot, so each boot re-picks).
# You normally never set anything. HUB_OWNER in the config is an optional
# override: if set to a username, that user is always the owner regardless of
# login order.

HUB_OWNER_STATE=/run/audiod-hub-owner

hub_owner_uname() {             # -> the configured owner's username, or empty
    printf '%s' "${HUB_OWNER:-}"
}

# Read-only: is <uid> the owner right now? (does NOT claim). Used for status.
hub_is_owner() {                # hub_is_owner <uid>
    local uid="$1" owner; owner=$(hub_owner_uname)
    if [ -n "$owner" ]; then
        local want; want=$(id -u "$owner" 2>/dev/null) || return 1
        [ "$uid" = "$want" ]; return
    fi
    # dynamic owner: compare against the recorded first-login owner
    local cur=""
    [ -r "$HUB_OWNER_STATE" ] && cur=$(cat "$HUB_OWNER_STATE" 2>/dev/null)
    if [ -n "$cur" ]; then
        [ "$uid" = "$cur" ]; return
    fi
    # nobody has claimed yet -> for display purposes this uid would be owner
    return 0
}

# Claim ownership for <uid> if it is free. Returns 0 if <uid> is (now) the
# owner, 1 if someone else already owns it. Writes the /run state on claim.
hub_claim_owner() {             # hub_claim_owner <uid>
    local uid="$1" owner; owner=$(hub_owner_uname)
    if [ -n "$owner" ]; then
        # explicit override in config
        local want; want=$(id -u "$owner" 2>/dev/null) || return 1
        [ "$uid" = "$want" ]; return
    fi
    local cur=""
    [ -r "$HUB_OWNER_STATE" ] && cur=$(cat "$HUB_OWNER_STATE" 2>/dev/null)
    if [ -n "$cur" ]; then
        [ "$uid" = "$cur" ]; return          # already owned (maybe by us)
    fi
    # free: claim it
    mkdir -p "$(dirname "$HUB_OWNER_STATE")" 2>/dev/null
    printf '%s\n' "$uid" > "$HUB_OWNER_STATE" 2>/dev/null
    log "hub: uid $uid is the first hub member in -> claiming owner"
    return 0
}

# Release ownership if <uid> currently holds it (owner logged out), so the next
# member to log in becomes owner. No-op when HUB_OWNER is pinned in config.
hub_release_owner() {           # hub_release_owner <uid>
    local uid="$1"
    [ -n "${HUB_OWNER:-}" ] && return 0      # pinned owner: never release
    local cur=""
    [ -r "$HUB_OWNER_STATE" ] && cur=$(cat "$HUB_OWNER_STATE" 2>/dev/null)
    if [ "$uid" = "$cur" ]; then
        : > "$HUB_OWNER_STATE" 2>/dev/null   # empty it (no rm); next login claims
        log "hub: owner uid $uid logged out -> ownership released"
    fi
}

# For a guest member: stop their local PipeWire's grip on Bluetooth by writing a
# per-user WirePlumber drop-in that disables the bluez monitor, so their session
# never steals the shared adapter from the owner. Reversible (remove the file).
hub_guest_bt_off() {            # hub_guest_bt_off <uid>
    local uid="$1" home
    home=$(getent passwd "$uid" 2>/dev/null | cut -d: -f6)
    [ -n "$home" ] && [ -d "$home" ] || return 0
    local d="$home/.config/wireplumber/wireplumber.conf.d"
    local f="$d/89-audiod-hub-no-bluez.conf"
    hub_as_user "$uid" mkdir -p "$d" 2>/dev/null || return 0
    if [ ! -f "$f" ]; then
        # write as the user so ownership/permittions are theirs
        hub_as_user "$uid" sh -c "cat > '$f'" <<'WPEOF' 2>/dev/null
# Installed by audiod hub mode for a guest hub member: do not grab the shared
# Bluetooth adapter (the hub owner holds it). Remove this file to restore.
wireplumber.profiles = {
  main = {
    monitor.bluez = disabled
  }
}
WPEOF
        log "hub: uid $uid is a guest member; disabled bluez in their WirePlumber"
        # restart just their wireplumber so the drop-in takes effect
        hub_as_user "$uid" sh -c 'daemon --pidfiles=~/.run --name=wireplumber --stop' 2>/dev/null
        sleep 0.4
        hub_as_user "$uid" sh -c 'daemon -rB --pidfiles=~/.run --name=wireplumber -- /usr/bin/wireplumber' 2>/dev/null
    fi
}

# Re-enable the bluez monitor for a user who is (now) the owner: move the guest
# drop-in OUT of the conf.d directory if it's there, so WirePlumber stops seeing
# it and loads the bluez monitor again. This undoes hub_guest_bt_off when a
# former guest becomes owner (e.g. the previous owner logged out). No-op if the
# drop-in isn't present. NOTE: emptying the file in place is NOT enough --
# WirePlumber still parses a zero-byte drop-in and the monitor stays off -- so we
# rename it out of conf.d (kept as .bak, not deleted).
hub_guest_bt_on() {             # hub_guest_bt_on <uid>
    local uid="$1" home
    home=$(getent passwd "$uid" 2>/dev/null | cut -d: -f6)
    [ -n "$home" ] && [ -d "$home" ] || return 0
    local d="$home/.config/wireplumber/wireplumber.conf.d"
    local f="$d/89-audiod-hub-no-bluez.conf"
    [ -f "$f" ] || return 0
    # move it out of conf.d so WirePlumber no longer reads it (no rm)
    hub_as_user "$uid" mv -f "$f" "$d/../89-audiod-hub-no-bluez.conf.bak" 2>/dev/null
    log "hub: uid $uid is owner; removed guest bluez-disable drop-in (bluez back on)"
    hub_as_user "$uid" sh -c 'daemon --pidfiles=~/.run --name=wireplumber --stop' 2>/dev/null
    sleep 0.4
    hub_as_user "$uid" sh -c 'daemon -rB --pidfiles=~/.run --name=wireplumber -- /usr/bin/wireplumber' 2>/dev/null
}

# ---- Network audio (trusted LAN machines send to this box) -----------------
#
# OFF unless NET_TCP=yes AND NET_ACL lists explicit addresses. We never open to
# the whole network implicitly.

hub_net_init() {                # hub_net_init <uid>
    [ "${NET_TCP:-no}" = "yes" ] || return 0

    local acl="${NET_ACL:-}"
    if [ -z "$acl" ]; then
        log "hub: NET_TCP=yes but NET_ACL is empty -> refusing to open network audio"
        log "hub: set NET_ACL to specific addresses (e.g. 192.168.1.0/24) to enable"
        return 0
    fi

    local port="${NET_PORT:-4713}"
    # Already loaded? (match our port)
    if hub_as_user "$uid" pactl list short modules 2>/dev/null \
        | awk -v p="port=$port" '$2=="module-native-protocol-tcp" && $0~p{f=1} END{exit !f}'; then
        log "hub: network audio already enabled on :$port"
        return 0
    fi

    if hub_as_user "$uid" pactl load-module module-native-protocol-tcp \
        port="$port" auth-ip-acl="$acl" >/dev/null 2>&1; then
        log "hub: network audio enabled on :$port for [$acl]"
        log "hub: WARNING network clients on the ACL can also see this box's mic/monitors"
    else
        log "hub: failed to enable network audio"
    fi
}

# ---- Combine sink (mirror to several outputs) ------------------------------
#
# Play the same audio on more than one output at once (internal speakers + HDMI
# + a BT speaker, whatever you like). Controlled by COMBINE=yes.
#
# COMBINE_SLAVES:
#   empty      -> combine ALL current sinks (Speaker, HDMI, any BT speaker).
#                 HDMI is intentionally included: gamers/AV setups do want it.
#   a,b,c      -> combine ONLY those sinks (comma-separated pactl sink names,
#                 e.g. ...HiFi__Speaker__sink,bluez_output.XX_XX_..._1).
#
# When created, hub_combined is made the DEFAULT sink so everything you play
# lands on all chosen outputs without extra steps.

hub_combined_id() {             # -> pactl sink id of hub_combined, or empty
    local uid="$1"
    hub_as_user "$uid" pactl list short sinks 2>/dev/null \
        | awk '$2=="hub_combined"{print $1; exit}'
}

hub_combine_init() {            # hub_combine_init <uid>
    [ "${COMBINE:-no}" = "yes" ] || return 0

    # Already there? Just (re)assert it as default and stop.
    if hub_as_user "$uid" pactl list short modules 2>/dev/null \
        | grep -q 'module-combine-sink'; then
        log "hub: combine-sink already present"
        hub_as_user "$uid" pactl set-default-sink hub_combined >/dev/null 2>&1
        return 0
    fi

    # Build args. Modern PipeWire's pipewire-pulse accepts the PulseAudio
    # module-combine-sink with sink_name + (optional) sinks=. Empty sinks= means
    # "all", which is the module's default when the arg is omitted.
    local args="sink_name=hub_combined"
    if [ -n "${COMBINE_SLAVES:-}" ]; then
        # accept either "slaves" spelling from older notes, normalise to sinks=
        args="$args sinks=${COMBINE_SLAVES}"
        log "hub: combine slaves = ${COMBINE_SLAVES}"
    else
        log "hub: combine slaves = <all current sinks>"
    fi

    if hub_as_user "$uid" pactl load-module module-combine-sink $args >/dev/null 2>&1; then
        # give the node a moment to appear, then make it the default
        local tries=10
        while [ "$tries" -gt 0 ]; do
            [ -n "$(hub_combined_id "$uid")" ] && break
            sleep 0.2; tries=$((tries-1))
        done
        if hub_as_user "$uid" pactl set-default-sink hub_combined >/dev/null 2>&1; then
            log "hub: combine-sink 'hub_combined' created and set as default"
        else
            log "hub: combine-sink created, but could not set it as default"
        fi
    else
        log "hub: failed to create combine-sink"
    fi
}

# Remove the combine sink and fall back to a real sink as default.
hub_combine_off() {             # hub_combine_off <uid>
    local uid="$1" id
    id=$(hub_as_user "$uid" pactl list short modules 2>/dev/null \
         | awk '$2=="module-combine-sink"{print $1; exit}')
    [ -n "$id" ] || { log "hub: no combine-sink to remove"; return 0; }
    hub_as_user "$uid" pactl unload-module "$id" >/dev/null 2>&1
    # pick any real sink as the new default (first non-combine one)
    local newdef
    newdef=$(hub_as_user "$uid" pactl list short sinks 2>/dev/null \
             | awk '$2!="hub_combined"{print $2; exit}')
    [ -n "$newdef" ] && hub_as_user "$uid" pactl set-default-sink "$newdef" >/dev/null 2>&1
    log "hub: combine-sink removed; default sink -> ${newdef:-<unchanged>}"
}

# ---- entry points called by the reactor ------------------------------------

# Called after the core stack is up, for EACH user that logs in. The hub only
# acts for members of HUB_GROUP; everyone else is ignored. Because the machine
# has a single, system-wide Bluetooth adapter, the BT parts are shared: any
# allowed user can open a pairing window and paired phones reconnect regardless
# of who is logged in. The network and combine parts are per-user (each member
# gets them on their own PipeWire).
hub_start() {                   # hub_start <uid>
    hub_enabled || return 0
    local uid="$1"

    if ! hub_user_allowed "$uid"; then
        dbg "hub: uid $uid not in group ${HUB_GROUP:-audiohub}; skip"
        return 0
    fi

    if hub_claim_owner "$uid"; then
        log "hub: uid $uid is the hub OWNER -> BT + card + per-user extras"
        hub_guest_bt_on  "$uid"     # undo any leftover guest bluez-disable drop-in
        hub_bt_init      "$uid"     # owner holds the shared adapter
        hub_btwatch_start "$uid"    # auto-reconnect BT on VT-switch-back
        hub_net_init     "$uid"     # owner exposes network audio (if configured)
        hub_combine_init "$uid"     # owner's combine sink (if configured)
        log "hub: owner ready for uid $uid"
    else
        # A second hub member on another seat/VT. Do NOT let them grab the shared
        # BT device from the owner: disable bluez in their WirePlumber. To HEAR
        # the hub they connect as an audioshare guest (they don't hold the card).
        log "hub: uid $uid is a hub GUEST member (owner already claimed)"
        hub_guest_bt_off "$uid"
        log "hub: guest ready for uid $uid -- to hear the hub, use: audioshare-guest connect"
    fi
}

# Called when an allowed user's stack is torn down.
hub_stop() {                    # hub_stop <uid>
    hub_enabled || return 0
    local uid="$1"
    hub_user_allowed "$uid" || return 0
    # If this was the owner, stop their BT watcher and release ownership.
    hub_btwatch_stop "$uid"
    hub_release_owner "$uid"
    # We do NOT power the adapter off (other members may still be using it).
    log "hub: user $uid (hub member) logged out; shared BT adapter left as-is"
}
