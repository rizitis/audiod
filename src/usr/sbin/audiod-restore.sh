#!/bin/bash
# audiod-restore.sh
#
# Revert audiod-takeover.sh: re-enable Slackware's stock PipeWire start
# mechanisms (profile.d + XDG autostart). Does NOT touch PulseAudio settings.
# Run as root. (Stop audiod first if you no longer want it: rc.audiod stop.)

if [ "$(id -u)" != 0 ]; then echo "run as root." >&2; exit 1; fi

echo "Console profile.d starters:"
# Since Slackware's pipewire 1.6.8-2 the profile.d starters ship NON-executable
# on purpose ("it'll be opt-in") -- /etc/profile only sources +x files, and the
# graphical XDG autostart entry is what starts PipeWire on a desktop. So the
# stock state to restore is "not executable": we deliberately do NOT chmod +x
# here, or we would be enabling more than stock ever did. If you want the
# console starter back, opt in yourself:
#     chmod +x /etc/profile.d/pipewire.sh /etc/profile.d/pipewire.csh
for f in /etc/profile.d/pipewire.sh /etc/profile.d/pipewire.csh; do
    if [ -f "$f" ]; then
        if [ -x "$f" ]; then
            echo "  $f is executable (console autostart opted in) -- left as is"
        else
            echo "  $f left non-executable (stock default; chmod +x to opt in)"
        fi
    fi
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
