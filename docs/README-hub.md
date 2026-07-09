# audiod hub mode (party audio hub)

`HUB_MODE` is an **optional** extension to audiod. With `HUB_MODE=no` (the
default) audiod behaves exactly like the stock build -- none of this runs. Turn
it on only when you want the box to act as a party audio hub.

## What it does

* **Bluetooth speaker (phones play THROUGH the box).** Friends pair their phones
  (with the normal PIN) and their music plays on the box's speakers, mixed by
  PipeWire. Paired phones are trusted so BlueZ reconnects them on its own.
* **Combine output (one sound everywhere).** Optionally mirror playback to all
  outputs at once -- built-in speakers, HDMI, and any Bluetooth speaker -- so
  the same music plays across the room.
* **Media control from the box.** `audioctl hub play|pause|next|prev` drives the
  connected phone over AVRCP, so you can control the music from the keyboard
  without touching someone's phone.
* **Network audio (optional).** Trusted LAN machines can stream to the box.

## Permissions: group-based, per-user

Only members of `HUB_GROUP` (default `audiohub`) get hub behaviour. Everyone
else is ignored. Create the group and add members (Slackware does this by hand):

```sh
groupadd audiohub
gpasswd -a alice audiohub
```

If the group does not exist, nobody is allowed (safe default).

## Ownership (automatic)

The card and the single system-wide Bluetooth adapter can only be held by one
user at a time. The **first** hub member to log in automatically becomes the
**owner** (holds the card + BT); later members are kept from grabbing the shared
adapter. You normally set nothing. `HUB_OWNER=<user>` in the config is an
optional override to pin ownership to a specific user. Ownership is remembered
in `/run` and clears on reboot.

## VT switching and Bluetooth

On this kind of setup, switching to another VT makes the owner's session
inactive, and the card/BT handoff would otherwise cut the phone's A2DP stream
mid-buffer -- the speakers then repeat the last buffer as a loud drone. The hub
runs a small per-owner watcher (`hub-btwatch.sh`) that listens to elogind for
active-session changes and:

* when the owner leaves the active VT -> **pauses the phone and suspends the BT
  stream cleanly**, so there is no drone;
* when the owner comes back -> **reconnects and resumes** (best-effort; some
  phones block remote resume, in which case you tap play once).

You can also recover manually any time with `audioctl hub reconnect`.

## Security posture

* Only `audiohub` members can use the hub.
* **Bluetooth pairing is bounded + on-demand.** `audioctl hub pair` makes the
  box discoverable for a short window (default 120s) that you trigger; pairing
  needs the normal PIN/confirmation -- no blind auto-accept, never permanently
  discoverable.
* **Network audio is deny-by-default.** `NET_TCP=yes` alone does nothing; you
  must set `NET_ACL` to explicit addresses. Anyone allowed in can also see that
  user's mic/monitors -- only allow machines you trust.
* audiod does not manage system services: `bluetoothd` must already be running
  and the adapter powered (an rc.d concern).

## Configuration (`/etc/audiod/audiod.conf`)

```
HUB_MODE=no              # master switch; yes = enable hub
HUB_GROUP=audiohub       # only members of this group get the hub
HUB_OWNER=               # empty = first login wins; or pin a username
BT_PAIR_SECONDS=120      # length of the 'audioctl hub pair' window

NET_TCP=no               # network audio in (per-user)
NET_ACL=                 # REQUIRED allow-list, e.g. 192.168.1.0/24 (empty=off)
NET_PORT=4713

COMBINE=no               # mirror playback to several outputs, made default sink
COMBINE_SLAVES=          # empty = ALL sinks (Speaker+HDMI+BT); or a,b to restrict
```

## Usage

```
audioctl hub status              # HUB_MODE, your role (owner/guest), BT/net/combine
audioctl hub pair [seconds]      # open a Bluetooth pairing window
audioctl hub play|pause|next|prev  # control the connected phone (AVRCP)
audioctl hub reconnect           # reconnect BT to you (manual recovery)
audioctl hub combine [off]       # create (or remove) the combine sink
audioctl hub net                 # (re)apply network audio from the config
```

## What it intentionally does NOT do

* It does not leave Bluetooth discoverable permanently, and never auto-accepts
  unknown devices (PIN/confirm always required).
* It does not open network audio without an explicit allow-list.
* It does not give non-members any hub access.
* It does not manage bluetoothd or the system bus.
* It does not make two different local users share one card at once (kernel/ALSA
  limit; see the separate `audioshare` project for host+guests).
