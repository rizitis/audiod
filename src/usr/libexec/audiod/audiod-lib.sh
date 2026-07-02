# /usr/libexec/audiod/audiod-lib.sh
#
# Shared logic for audiod (runs as root) and audioctl (runs as the user).
# Sourced, not executed. Requires bash (Slackware /bin/sh is bash).
#
# Design invariants (agreed):
#   * Event source is elogind's org.freedesktop.login1; we never modify elogind.
#   * The payload is supervised by libslack daemon(1) with pidfiles in ~/.run,
#     exactly like Slackware's stock pipewire start scripts.
#   * We only ever touch service NAMES listed in stack.conf. Never a blanket
#     "kill everything in ~/.run" -- that directory holds unrelated pidfiles.
#   * Privilege drop root->user is setpriv (no PAM, no new elogind session).

AUDIOD_CONF=/etc/audiod/audiod.conf
AUDIOD_STACK=/etc/audiod/stack.conf

load_config() {
    # defaults
    AUDIO_SERVER=auto
    MANAGE_DBUS=no
    DEBUG=no
    SEAT_WAIT=5
    PIPEWIRE_WAIT=10
    BUS_WAIT=3
    [ -r "$AUDIOD_CONF" ] && . "$AUDIOD_CONF"
}

log() {
    logger -t audiod -- "$*" 2>/dev/null
    [ "${DEBUG:-no}" = yes ] && printf 'audiod: %s\n' "$*" >&2
    return 0
}
dbg() { [ "${DEBUG:-no}" = yes ] && log "$*"; return 0; }

# --- passwd helpers ---------------------------------------------------------
user_for() { getent passwd "$1" | cut -d: -f1; }
gid_for()  { getent passwd "$1" | cut -d: -f4; }
home_for() { getent passwd "$1" | cut -d: -f6; }
rundir_for() { echo "$(home_for "$1")/.run"; }

# --- audio-server mode (respect Slackware's switch) -------------------------
# return 0 = PipeWire mode (manage), 1 = PulseAudio mode (stand down)
#
# Slackware's pipewire-enable.sh / pipewire-disable.sh flip the audio server by
# renaming the XDG autostart entries. In PulseAudio mode, pulseaudio.desktop is
# active and pipewire.desktop has been renamed to pipewire.desktop.sample. That
# rename is the authoritative switch, so we read it directly. (Our own takeover
# only appends Hidden=true to pipewire.desktop, it never renames it, so a
# taken-over PipeWire system still has pipewire.desktop present.)
is_pipewire_mode() {
    local ad="${AUDIOD_AUTOSTART_DIR:-/etc/xdg/autostart}"
    case "$AUDIO_SERVER" in
        pipewire) return 0 ;;
        pulse)    return 1 ;;
    esac
    # no pulse installed at all -> always PipeWire
    [ -x /usr/bin/pulseaudio ] || return 0

    # authoritative: pulseaudio autostart active AND pipewire autostart sampled out
    if [ -e "$ad/pulseaudio.desktop" ] && [ ! -e "$ad/pipewire.desktop" ]; then
        return 1                                       # PulseAudio mode
    fi

    # secondary hint: client.conf autospawn (also set by the switch scripts)
    if [ -r /etc/pulse/client.conf ] && \
       grep -Eq '^[[:space:]]*autospawn[[:space:]]*=[[:space:]]*yes' \
            /etc/pulse/client.conf; then
        return 1                                       # PulseAudio autospawn on
    fi
    return 0                                            # PipeWire mode
}

# --- run a command as the target user --------------------------------------
# run_as_user <uid> <cmd...>
#   root  -> setpriv (clean env, correct groups, no PAM/session)
#   user  -> run directly, inheriting the live session environment
run_as_user() {
    local uid="$1"; shift
    if [ "$(id -u)" = "0" ] && [ "$uid" != "0" ]; then
        local u g h
        u=$(user_for "$uid"); g=$(gid_for "$uid"); h=$(home_for "$uid")
        setpriv --reuid "$uid" --regid "$g" --init-groups \
            env -i \
                HOME="$h" USER="$u" LOGNAME="$u" \
                XDG_RUNTIME_DIR="/run/user/$uid" \
                PATH=/usr/bin:/bin:/usr/sbin:/sbin \
                ${DBUS_ADDR:+DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR"} \
                "$@"
    else
        if [ -n "${DBUS_ADDR:-}" ]; then
            DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" "$@"
        else
            "$@"
        fi
    fi
}

# --- libslack daemon(1) service primitives ----------------------------------
service_running() {         # service_running <uid> <name>
    local uid="$1" name="$2" rd; rd=$(rundir_for "$uid")
    run_as_user "$uid" daemon --pidfiles="$rd" --name="$name" --running
}

start_service() {           # start_service <uid> <name> <binary> [args...]
    local uid="$1" name="$2" bin="$3"; shift 3
    local rd; rd=$(rundir_for "$uid")
    run_as_user "$uid" mkdir -p "$rd"
    if service_running "$uid" "$name"; then
        dbg "$name already running for uid $uid"; return 0
    fi
    log "start $name (uid $uid)"
    run_as_user "$uid" daemon -rB --pidfiles="$rd" --name="$name" -- "$bin" "$@"
}

stop_service() {            # stop_service <uid> <name>
    local uid="$1" name="$2" rd; rd=$(rundir_for "$uid")
    if service_running "$uid" "$name"; then
        log "stop $name (uid $uid)"
        run_as_user "$uid" daemon --pidfiles="$rd" --name="$name" --stop
    fi
}

# --- readiness --------------------------------------------------------------
wait_socket() {             # wait_socket <path> <timeout_s>
    local path="$1" timeout="$2" i=0 max=$(( ${2:-5} * 5 ))
    while [ "$i" -lt "$max" ]; do
        [ -S "$path" ] && return 0
        sleep 0.2; i=$((i + 1))
    done
    return 1
}

# --- session bus ------------------------------------------------------------
# True if something is actually listening on the given unix-socket bus path,
# so we never latch onto a stale/zombie socket left by a dead dbus-daemon.
bus_alive() {               # bus_alive <path>
    local path="$1"
    [ -S "$path" ] || return 1
    # a live bus has a process holding the socket open
    if command -v fuser >/dev/null 2>&1; then
        fuser "$path" >/dev/null 2>&1 && return 0
    fi
    # fallback: is any dbus-daemon bound to this exact address?
    pgrep -f -- "--address=unix:path=$path" >/dev/null 2>&1 && return 0
    return 1
}

# Discover an existing session bus for the user, wherever it lives. Desktops
# started via dbus-run-session (e.g. SDDM+Plasma) put the bus in /tmp and only
# advertise it through DBUS_SESSION_BUS_ADDRESS in the session environment, so
# checking /run/user/$uid/bus alone is not enough -- we inspect the environ of
# the user's own processes. A standard-path socket is only trusted if a live
# process is actually serving it (avoids zombie sockets from old runs).
detect_user_bus() {         # detect_user_bus <uid> ; echoes address or nothing
    local uid="$1" pid addr
    # standard path first (cheap), but only if actually alive
    if bus_alive "/run/user/$uid/bus"; then
        echo "unix:path=/run/user/$uid/bus"; return 0
    fi
    # otherwise scan the user's processes for an advertised bus
    for pid in $(pgrep -u "$uid" 2>/dev/null); do
        addr=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
               | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n1)
        [ -n "$addr" ] && { echo "$addr"; return 0; }
    done
    return 1
}

# sets global DBUS_ADDR (may be empty if MANAGE_DBUS=no and none present)
ensure_session_bus() {      # ensure_session_bus <uid>
    local uid="$1" bus="/run/user/$uid/bus" existing i max

    # 1) already have one somewhere (desktop /tmp bus, or standard path)?
    if existing=$(detect_user_bus "$uid"); then
        DBUS_ADDR="$existing"
        dbg "session bus already present for uid $uid ($existing)"
        return 0
    fi

    if [ "${MANAGE_DBUS:-no}" != yes ]; then
        dbg "no session bus, MANAGE_DBUS=no -> pipewire will run without one"
        DBUS_ADDR=""; return 0
    fi

    # 2) MANAGE_DBUS=yes and none yet: a graphical session may be bringing its
    #    own up concurrently (dbus-run-session). Give it a bounded chance so we
    #    don't spawn a redundant second bus, then spawn only if still absent.
    i=0; max=$(( ${BUS_WAIT:-3} * 4 ))
    while [ "$i" -lt "$max" ]; do
        if existing=$(detect_user_bus "$uid"); then
            DBUS_ADDR="$existing"
            dbg "session bus appeared for uid $uid ($existing)"
            return 0
        fi
        sleep 0.25; i=$((i + 1))
    done

    # 3) genuinely no bus (console/bare-WM): provide one at the standard path.
    DBUS_ADDR="unix:path=$bus"
    log "spawn session bus (uid $uid) at $bus"
    local rd; rd=$(rundir_for "$uid")
    run_as_user "$uid" mkdir -p "$rd"
    run_as_user "$uid" daemon -rB --pidfiles="$rd" --name=dbus \
        -- /usr/bin/dbus-daemon --session --address="unix:path=$bus" \
        --nofork --nopidfile
    wait_socket "$bus" 5 || log "warning: session bus socket did not appear"
}

# --- stack operations -------------------------------------------------------
start_stack() {             # start_stack <uid>
    local uid="$1"
    ensure_session_bus "$uid"
    local name bin ready
    while read -r name bin ready _; do
        case "$name" in ''|\#*) continue ;; esac
        start_service "$uid" "$name" "$bin"
        case "$ready" in
            socket:*)
                local sock="/run/user/$uid/${ready#socket:}"
                wait_socket "$sock" "${PIPEWIRE_WAIT:-10}" \
                    || log "warning: $name socket $sock not ready; continuing"
                ;;
        esac
    done < "$AUDIOD_STACK"
}

stop_stack() {              # stop_stack <uid> ; reverse order, targeted only
    local uid="$1" name bin ready rev=""
    while read -r name bin ready _; do
        case "$name" in ''|\#*) continue ;; esac
        rev="$name $rev"
    done < "$AUDIOD_STACK"
    for name in $rev; do
        stop_service "$uid" "$name"
    done
    # our own bus, only if we started one under the 'dbus' name
    stop_service "$uid" dbus
}

status_stack() {            # status_stack <uid>
    local uid="$1" name bin ready
    if service_running "$uid" dbus; then
        echo "  dbus            : running (managed by audiod)"
    fi
    while read -r name bin ready _; do
        case "$name" in ''|\#*) continue ;; esac
        if service_running "$uid" "$name"; then
            printf '  %-15s : running\n' "$name"
        else
            printf '  %-15s : stopped\n' "$name"
        fi
    done < "$AUDIOD_STACK"
}

restart_one() {             # restart_one <uid> <name>
    local uid="$1" want="$2" name bin ready found=""
    while read -r name bin ready _; do
        case "$name" in ''|\#*) continue ;; esac
        if [ "$name" = "$want" ]; then found="$bin"; break; fi
    done < "$AUDIOD_STACK"
    if [ -z "$found" ]; then
        echo "audioctl: unknown component '$want'" >&2; return 1
    fi
    stop_service "$uid" "$want"; sleep 0.5
    start_service "$uid" "$want" "$found"
}
