#!/bin/bash
# audiod-restore.sh
#
# Revert audiod-takeover.sh: re-enable Slackware's stock PipeWire start
# mechanisms (profile.d + XDG autostart). Does NOT touch PulseAudio settings.
# Run as root. (Stop audiod first if you no longer want it: rc.audiod stop.)

if [ "$(id -u)" != 0 ]; then echo "run as root." >&2; exit 1; fi

echo "Re-enabling console profile.d starters:"
for f in /etc/profile.d/pipewire.sh /etc/profile.d/pipewire.csh; do
    [ -f "$f" ] && chmod +x "$f" && echo "  chmod +x $f"
done

echo "Un-hiding graphical XDG autostart entries:"
for f in wireplumber pipewire-pulse pipewire; do
    d="/etc/xdg/autostart/${f}.desktop"
    if [ -r "$d" ] && grep -q '^Hidden=true$' "$d"; then
        grep -v '^Hidden=true$' "$d" > "${d}.tmp" && mv "${d}.tmp" "$d"
        echo "  un-hid $d"
    fi
done

echo
echo "Done. Stock start mechanisms restored."
echo "If audiod is still running, stop/disable it:"
echo "  /etc/rc.d/rc.audiod stop ; chmod -x /etc/rc.d/rc.audiod"
