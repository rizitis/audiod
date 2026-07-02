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

echo "Disabling console profile.d starters (Slackware sources only +x files):"
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
