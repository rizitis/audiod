config() {
  NEW="$1"
  OLD="$(dirname $NEW)/$(basename $NEW .new)"
  # If there's no config file by that name, mv it over:
  if [ ! -r $OLD ]; then
    mv $NEW $OLD
  elif [ "$(cat $OLD | md5sum)" = "$(cat $NEW | md5sum)" ]; then
    # toss the redundant copy
    rm $NEW
  fi
  # Otherwise, we leave the .new copy for the admin to consider...
}

# rc.audiod: the execute bit is the admin's on/off switch. Preserve it across
# upgrades: note whether the currently-installed rc is executable, run the
# normal config() handling, then restore the execute bit if it was set.
RC=etc/rc.d/rc.audiod
RC_WAS_ON=no
[ -x "$RC" ] && RC_WAS_ON=yes
config "$RC.new"
if [ "$RC_WAS_ON" = yes ] && [ -f "$RC" ]; then
  chmod +x "$RC"
fi

# Config files: never clobber local edits.
config etc/audiod/audiod.conf.new
config etc/audiod/stack.conf.new
