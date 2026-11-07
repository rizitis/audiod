#!/bin/bash
# audiod-restore.sh
#
# Revert audiod-takeover.sh: re-enable Slackware's stock PipeWire start
# mechanisms (profile.d + XDG autostart). Does NOT touch PulseAudio settings.
# Also removes the hub guest drop-ins from users' homes. removepkg audiod
# does all of this itself through douninst.sh; this script is for going back
# to the stock start while keeping the package.
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

echo "Removing hub guest drop-ins (they keep Bluetooth off in WirePlumber):"
# Written into users' homes by hub mode; removepkg does not know about them.
# Moved, not deleted, and as the user so nothing is done as root in their home.
found=no
while IFS=: read -r name _ uid gid _ home _; do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ "$uid" -lt 60000 ] || continue
    f="$home/.config/wireplumber/wireplumber.conf.d/89-audiod-hub-no-bluez.conf"
    [ -f "$f" ] || continue
    found=yes
    if setpriv --reuid "$uid" --regid "$gid" --init-groups \
        mv -f "$f" "$home/.config/wireplumber/89-audiod-hub-no-bluez.conf.bak"; then
        echo "  moved $f (user $name: restart wireplumber or log in again)"
    else
        echo "  FAILED to move $f -- remove it by hand, Bluetooth is off for $name"
    fi
done < <(getent passwd)
[ "$found" = no ] && echo "  none found"
rm -f /run/audiod-hub-owner /run/audiod-hub-owner.lock

echo
echo "Done. Stock start mechanisms restored."
echo "If audiod is still running, stop/disable it:"
echo "  /etc/rc.d/rc.audiod stop ; chmod -x /etc/rc.d/rc.audiod"
