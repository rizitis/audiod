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
* **Self-healing pulse-side objects.** `hub_combined` and the network-audio
  module are loaded *into* `pipewire-pulse` and die with it. Its supervisor
  restarts the service, so afterwards the stack looks perfectly healthy while
  the hub is silently gone -- and no login1 signal is raised, so nothing would
  rebuild it. `hub-pulsewatch.sh` notices the server was replaced and re-applies
  the owner's extras.

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

A `HUB_OWNER` that is not an existing user is ignored with a WARNING in the log
(before 3.1 it silently made every member a guest). A recorded owner with no
local session left is released when the next member logs in.

Guests get `~/.config/wireplumber/wireplumber.conf.d/89-audiod-hub-no-bluez.conf`,
which turns WirePlumber's bluez monitor off: **no Bluetooth at all for that
user** while it exists. It is removed on the guest's logout, when the user
becomes owner, on the next login when hub mode no longer applies to that user,
and by `audiod-restore.sh`. `audioctl hub status` shows it on the `bluez (WP)`
line.

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

HUB_BT_AUTORESUME=no     # reconnect BT when you switch back to your VT
HUB_BT_AUTOPLAY=no       # also send AVRCP play on reconnect (needs AUTORESUME)

NET_TCP=no               # network audio in (per-user)
NET_ACL=                 # REQUIRED allow-list, e.g. 192.168.1.0/24 (empty=off)
NET_PORT=4713

COMBINE=no               # mirror playback to several outputs, made default sink
COMBINE_SLAVES=          # empty = ALL sinks (Speaker+HDMI+BT); or a,b to restrict
COMBINE_WAIT=15          # seconds to wait for a real sink before creating combine

HUB_PULSEWATCH_ENABLE=yes    # rebuild hub extras when pipewire-pulse restarts
HUB_PULSEWATCH_INTERVAL=5    # how often the watcher checks (seconds)
```

## Usage

```
audioctl hub status              # live state: role, BT, net, combine (not a config echo)
audioctl hub scan [seconds]      # scan + connect/disconnect a device by number
audioctl hub pair [seconds]      # open a Bluetooth pairing window
audioctl hub play|pause|next|prev  # control the connected phone (AVRCP)
audioctl hub reconnect           # reconnect BT to you (manual recovery)
audioctl hub combine [off]       # create (or remove) the combine sink
audioctl hub net                 # (re)apply network audio from the config
```

## Reading `audioctl hub status`

Every runtime line is a live query -- PipeWire for the combine sink, BlueZ for
Bluetooth, the state file for ownership, the guest drop-in for `bluez (WP)`, the
process table for the watchers. It
is deliberately not a summary of the config, because a status that echoes
configuration reports a healthy hub whether or not anything was created, and a
hub that silently failed to come up then looks identical to a working one.

Where configuration and reality disagree, the line says so:

```
  combine sink : COMBINE=yes but hub_combined DOES NOT EXIST  <-- mismatch
```

and a combine sink you turned off yourself is reported as a choice, not a fault:

```
  combine sink : off -- you switched it off ('audioctl hub combine off')
```

That choice is recorded in `/run/user/$uid/audiod-hub-combine`, so the
`pipewire-pulse` watcher does not put the sink back behind your back.

## Known limitations

* **The combine sink is static.** It mirrors to the outputs that existed when it
  was created. *Sources* come and go freely -- a new phone joins the mix
  instantly -- but a **new output** does not. Connect Bluetooth speakers before
  building the mix, or rebuild it with `audioctl hub combine off` followed by
  `audioctl hub combine`. Following new sinks dynamically would need the native
  `module-combine-stream` with `stream.rules` instead of the PulseAudio
  compatibility module; not done yet.
* **A microphone near loud speakers will howl.** Combine plays through the
  built-in speakers *and* the Bluetooth ones, and a laptop's mic array sits
  centimetres from the former. Recording while the hub is loud gives acoustic
  feedback -- physics, not a bug. Use a headset, or load `module-echo-cancel`.
* **Bluetooth resume after a VT switch is best-effort**; some phones block
  remote play.

## After a pipewire or pulseaudio upgrade

The symptom to watch for is **sound works, but the hub is gone**. That almost
always means `pactl` is talking to a different server than WirePlumber: a
standalone PulseAudio daemon and `pipewire-pulse` both want
`/run/user/$uid/pulse/native`, and whoever binds it first owns every `pactl`
call, so `hub_combined` is created inside PulseAudio while `wpctl` never sees it.

```sh
pactl info | grep -i 'server name'   # want: PulseAudio (on PipeWire x.y.z)
pgrep -a pulseaudio                  # want: nothing
sudo audiod-doctor.sh                # repairs both causes (--check to preview)
```

The two causes are an `/etc/xdg/autostart/pulseaudio.desktop` reinstated by the
upgrade, and a per-user `~/.config/pulse/client.conf`. libpulse uses the
per-user file *instead of* `/etc/pulse/client.conf` -- it does not merge them --
so a system-wide `autospawn = no` silently stops applying. A file containing
nothing but a commented-out line is enough to do this.

## What it intentionally does NOT do

* It does not leave Bluetooth discoverable permanently, and never auto-accepts
  unknown devices (PIN/confirm always required).
* It does not open network audio without an explicit allow-list.
* It does not give non-members any hub access.
* It does not manage bluetoothd or the system bus.
* It does not make two different local users share one card at once (kernel/ALSA
  limit; see the separate `audioshare` project for host+guests).
