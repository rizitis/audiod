#!/bin/bash
# audiod-takeover.sh
#
# Hand PipeWire startup from Slackware's stock mechanisms (profile.d console
# scripts + XDG autostart) over to audiod. Keeps PipeWire as the audio server;
# does NOT touch PulseAudio settings. Fully reversible with audiod-restore.sh.
#
# Run as root.

if [ "$(id -u)" != 0 ]; then echo "run as root." >&2; exit 1; fi
if [ ! -x /usr/bin/pipewire ]; then
    echo "error: /usr/bin/pipewire not found; nothing to do." >&2; exit 1
fi

# Refuse on a PulseAudio system: disabling the PipeWire starters while the
# machine is in Pulse mode (audiod stands down there) would leave NOTHING
# starting audio -> silence. Switch to PipeWire first. We reuse audiod's own
# mode detection so there is a single source of truth.
if [ -r /usr/libexec/audiod/audiod-lib.sh ]; then
    . /usr/libexec/audiod/audiod-lib.sh
    load_config
    if ! is_pipewire_mode; then
        echo "error: system is in PulseAudio mode." >&2
        echo "audiod manages PipeWire only; running takeover now would leave" >&2
        echo "no starter and thus no sound. Switch to PipeWire first" >&2
        echo "(e.g. Slackware's pipewire-enable.sh), then re-run takeover." >&2
        exit 1
    fi
fi

echo "Disabling console profile.d starters (Slackware sources only +x files):"
# Note: recent Slackware (pipewire >= 1.6.8) ships a profile.d/pipewire.sh that
# does an ordered start with a socket readiness gate AND an idempotency check
# (daemon --pidfiles=~/.run --name=pipewire --running && return 0), using the
# same ~/.run + --name=pipewire convention as audiod. So even if a copy is still
# sourced, it will NOT double-start PipeWire once audiod already has it running.
# We still chmod -x here so audiod is unambiguously the starter on setups whose
# /etc/profile honours the execute bit; on setups that source every *.sh the
# idempotency check is what keeps a single instance. Either way: one PipeWire.
for f in /etc/profile.d/pipewire.sh /etc/profile.d/pipewire.csh; do
    [ -f "$f" ] && chmod -x "$f" && echo "  chmod -x $f"
done

echo "Hiding graphical XDG autostart entries:"
for f in wireplumber pipewire-pulse pipewire; do
    d="/etc/xdg/autostart/${f}.desktop"
    if [ -r "$d" ] && ! grep -q '^Hidden=true$' "$d"; then
        echo "Hidden=true" >> "$d" && echo "  Hidden=true >> $d"
    fi
done

cat <<'EOF'

Done. PipeWire is now started and supervised per-user by audiod.

Enable audiod at boot (after elogind) and start it now:
  chmod +x /etc/rc.d/rc.audiod
  /etc/rc.d/rc.audiod start
  # and add to /etc/rc.d/rc.local:
  #   [ -x /etc/rc.d/rc.audiod ] && /etc/rc.d/rc.audiod start

If a stale copy from the old mechanism is running, clear it (as your user):
  audioctl restart
EOF
