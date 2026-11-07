#!/bin/sh
# douninst.sh -- run by removepkg after the package files are gone.
# Removes what removepkg cannot track: the config and rc script that doinst.sh
# renamed from .new, the takeover edits, the hub guest drop-ins in homes and
# the lines added to rc.local.
#
# removepkg runs this from $ROOT/ after it moved our package entry away, so
# paths are relative. upgradepkg removes the old package only after the new
# one is installed: if any audiod package is still installed this is an
# upgrade or reinstall, and nothing must be touched.

for p in var/lib/pkgtools/packages/audiod-*; do
  [ -e "$p" ] || continue
  n=${p##*/}
  n=${n%%-upgraded-*}
  # strip -VERSION-ARCH-BUILD, keep the base name only
  base=$(echo "$n" | rev | cut -d- -f4- | rev)
  [ "$base" = audiod ] && exit 0
done

# Live system only: processes, homes and users belong to the running system,
# not to an alternate $ROOT.
if [ -z "$ROOT" ] || [ "$ROOT" = / ]; then
  # stop the reactor and the hub watchers (their scripts are already gone)
  if [ -s run/audiod.pid ]; then
    kill -TERM "$(cat run/audiod.pid)" 2>/dev/null
  fi
  pkill -f '/usr/sbin/audiod$' 2>/dev/null
  pkill -f /usr/libexec/audiod/hub-btwatch.sh 2>/dev/null
  pkill -f /usr/libexec/audiod/hub-pulsewatch.sh 2>/dev/null
  rm -f run/audiod.pid run/audiod-hub-owner run/audiod-hub-owner.lock

  # hub guest drop-ins: they keep Bluetooth off in WirePlumber for that user.
  # Moved out of conf.d, as the user, never as root inside a home.
  getent passwd | while IFS=: read -r name _ uid gid _ home _; do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ "$uid" -lt 60000 ] || continue
    f="$home/.config/wireplumber/wireplumber.conf.d/89-audiod-hub-no-bluez.conf"
    [ -f "$f" ] || continue
    if setpriv --reuid "$uid" --regid "$gid" --init-groups \
        mv -f "$f" "$home/.config/wireplumber/89-audiod-hub-no-bluez.conf.bak"; then
      echo "audiod: removed hub guest drop-in for $name (restart wireplumber or log in again)"
    else
      echo "audiod: could not move $f, remove it by hand"
    fi
  done
fi

# undo audiod-takeover.sh: un-hide the PipeWire autostart entries
for f in wireplumber pipewire-pulse pipewire; do
  d="etc/xdg/autostart/${f}.desktop"
  if [ -r "$d" ] && grep -q '^Hidden=true$' "$d"; then
    grep -v '^Hidden=true$' "$d" > "$d.tmp" && cat "$d.tmp" > "$d"
    rm -f "$d.tmp"
    echo "audiod: un-hid /$d"
  fi
done

# config and rc script installed from .new by doinst.sh
rm -f etc/rc.d/rc.audiod etc/rc.d/rc.audiod.new
rm -f etc/audiod/audiod.conf etc/audiod/audiod.conf.new \
      etc/audiod/stack.conf etc/audiod/stack.conf.new
if [ -d etc/audiod ]; then
  if rmdir etc/audiod 2>/dev/null; then
    :
  else
    echo "audiod: /etc/audiod has other files, left in place:"
    ls -A etc/audiod | sed 's/^/  /'
  fi
fi

# rc.local: remove only the exact start block the docs tell you to add
# (with its comment line), nothing else.
if [ -f etc/rc.d/rc.local ] && grep -q 'rc\.audiod' etc/rc.d/rc.local; then
  awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^[ \t]*if \[ -x \/etc\/rc\.d\/rc\.audiod \]; then[ \t]*$/ &&
            line[i+1] ~ /^[ \t]*\/etc\/rc\.d\/rc\.audiod start[ \t]*$/ &&
            line[i+2] ~ /^[ \t]*fi[ \t]*$/) {
          if (n > 0 && out[n] ~ /^# .*audio session manager/) n--
          i += 2
          continue
        }
        if (line[i] ~ /^[ \t]*\[ -x \/etc\/rc\.d\/rc\.audiod \] && \/etc\/rc\.d\/rc\.audiod start[ \t]*$/) {
          if (n > 0 && out[n] ~ /^# .*audio session manager/) n--
          continue
        }
        out[++n] = line[i]
      }
      for (i = 1; i <= n; i++) print out[i]
    }' etc/rc.d/rc.local > etc/rc.d/rc.local.audiod-tmp
  if ! cmp -s etc/rc.d/rc.local etc/rc.d/rc.local.audiod-tmp; then
    # cat > keeps the original mode and owner of rc.local
    cat etc/rc.d/rc.local.audiod-tmp > etc/rc.d/rc.local
    echo "audiod: removed the rc.audiod start block from /etc/rc.d/rc.local"
  fi
  rm -f etc/rc.d/rc.local.audiod-tmp
  if grep -q 'rc\.audiod' etc/rc.d/rc.local; then
    echo "audiod: /etc/rc.d/rc.local still mentions rc.audiod, check it by hand"
  fi
fi

# The audiohub group is created by the admin, not by the package: report it.
if grep -q '^audiohub:' etc/group 2>/dev/null; then
  echo "audiod: group audiohub still exists (groupdel audiohub if unused)"
fi
