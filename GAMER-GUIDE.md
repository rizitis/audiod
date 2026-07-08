# audiod for Gamers — Turn Your Slackware Box Into a Party Audio Hub

This guide covers everything a gamer needs to know about `audiod` hub mode on a
Slackware machine: what it does, how to set it up, and every command you'll use.

`audiod` is a per-user audio session manager for non-systemd Slackware. Its
**hub mode** turns your gaming rig into an audio hub: friends pair their phones
over Bluetooth and their music plays through your speakers, sound mirrors to
every output at once (speakers + your HDMI monitor/TV + Bluetooth speakers), and
you control playback from your keyboard without touching anyone's phone.

---

## What you get

* **Bluetooth speaker mode.** Friends pair their phones (with a PIN) and play
  music straight through your rig. Multiple phones mix together.
* **Sound everywhere (combine).** The same audio plays on your built-in
  speakers, every HDMI output (monitor, TV, AV receiver), and any Bluetooth
  speaker — all at once. HDMI is included on purpose: your monitor/TV gets sound
  too.
* **Media control from the box.** Play, pause, skip tracks on the connected
  phone from your keyboard — no need to grab a friend's phone.
* **Auto-recovery on VT switch.** Alt-Tabbing between virtual terminals won't
  leave your speakers droning: the Bluetooth stream is paused cleanly when you
  leave and reconnected when you come back.
* **Network audio (optional).** Let a trusted friend's laptop on your LAN stream
  audio to the rig.
* **Zero core risk.** With hub mode off, `audiod` behaves exactly like the
  stock build. Everything here is opt-in.

---

## Requirements

* Slackware-current with `audiod` installed (hub build).
* `bluez` (BlueZ 5.x) installed, `bluetoothd` running, and a Bluetooth adapter.
  Check with: `bluetoothctl show` (should list a Controller, `Powered: yes`).
* `psmisc` (for `fuser`) — part of the Slackware base.
* PipeWire (`pipewire`, `wireplumber`, `pipewire-pulse`).

`audiod` does not manage system services. Make sure `bluetoothd` starts at boot
(`chmod +x /etc/rc.d/rc.bluetooth`) — that's a system concern, not audiod's.

---

## Install

### Option A — build the gamer preset (recommended for a gaming rig)

The SlackBuild ships a ready-to-go gamer config when you pass `GAME=ON`:

```sh
GAME=ON bash audiod.SlackBuild
sudo upgradepkg --install-new /tmp/audiod-0.2.0-noarch-8_rtz.txz
```

This installs a config with hub mode **on** and combine (sound everywhere)
**on** out of the box.

### Option B — build normal, enable by hand

```sh
bash audiod.SlackBuild
sudo upgradepkg --install-new /tmp/audiod-0.2.0-noarch-8_rtz.txz
# then edit /etc/audiod/audiod.conf and set HUB_MODE=yes (and COMBINE=yes)
```

---

## One-time setup

**1. Create the hub group and add yourself.** Only members of this group get hub
features (Slackware-style: you do this by hand):

```sh
sudo groupadd audiohub
sudo gpasswd -a YOURNAME audiohub
```

**Log out and back in** so the new group takes effect (`id -nG` should now list
`audiohub`).

**2. Make sure hub mode is on** in `/etc/audiod/audiod.conf`:

```
HUB_MODE=yes
```

(If you built with `GAME=ON`, this is already set.)

**3. Enable audiod at boot** (if you haven't already):

```sh
sudo chmod +x /etc/rc.d/rc.audiod
# add to /etc/rc.d/rc.local, after elogind is up:
#   [ -x /etc/rc.d/rc.audiod ] && /etc/rc.d/rc.audiod start
```

**4. Start it:**

```sh
sudo /etc/rc.d/rc.audiod restart
audioctl hub status
```

You should see `HUB_MODE: yes`, your membership as `member (allowed)`, and
`OWNER (holds card+BT)`.

---

## Every command you'll use

All hub commands run as your normal user (no root) via `audioctl hub`.

### Status

```sh
audioctl hub status
```
Shows hub mode, your group membership, whether you're the owner, and the state
of Bluetooth / network / combine.

### Bluetooth: pairing a phone

```sh
audioctl hub pair          # open a 120-second pairing window
audioctl hub pair 60       # ...or a 60-second window
```
Then on the phone: Bluetooth → scan → pick your box's name → pair (enter the PIN
if asked). Make sure **Media audio** is ON for the device on the phone side.

Once paired, the phone is trusted and reconnects on its own next time.

### Bluetooth: media control (from your keyboard)

```sh
audioctl hub play          # start playback on the connected phone
audioctl hub pause         # pause it
audioctl hub next          # next track
audioctl hub prev          # previous track
```
Handy at a party: skip a track without reaching for someone's phone. (Some
phones block remote "play"; pause/next/prev usually work regardless.)

### Bluetooth: manual reconnect

```sh
audioctl hub reconnect
```
If the phone's audio ever drops (e.g. after a lot of VT switching), this pulls
it back to you. Normally you won't need it — the watcher handles reconnects.

### Sound everywhere (combine)

```sh
audioctl hub combine       # mirror playback to ALL outputs, set as default
audioctl hub combine off   # stop mirroring, go back to a single output
```
With combine on, music plays on your speakers + every HDMI output + any
Bluetooth speaker at once. Toggle it live whenever you want.

### Network audio (optional, off by default)

Edit `/etc/audiod/audiod.conf`:
```
NET_TCP=yes
NET_ACL=192.168.1.0/24        # REQUIRED: your LAN, or a specific host
```
Then:
```sh
audioctl hub net              # apply it
```
Now a trusted machine on that network can send audio to your rig.

### Your own audio stack (works with or without hub)

```sh
audioctl status               # show your PipeWire stack
audioctl restart              # restart it if sound gets stuck
audioctl restart wireplumber  # restart just one component
```

---

## A typical party session

```sh
# once, at setup:
sudo groupadd audiohub && sudo gpasswd -a me audiohub   # then re-login

# start of the night:
audioctl hub status            # confirm you're the owner, BT available
audioctl hub combine           # sound everywhere (if not already on)
audioctl hub pair              # let a friend pair their phone

# friend plays music from their phone -> it fills the room
audioctl hub next              # skip a track from your keyboard
audioctl hub pair              # next friend pairs their phone too
```

---

## Config reference (`/etc/audiod/audiod.conf`)

```
HUB_MODE=yes             # master switch for hub mode
HUB_GROUP=audiohub       # only members of this group get the hub
HUB_OWNER=               # empty = first login owns the card+BT; or pin a name
BT_PAIR_SECONDS=120      # length of the 'audioctl hub pair' window

NET_TCP=no               # network audio in (off unless you set an ACL)
NET_ACL=                 # required allow-list to enable it, e.g. 192.168.1.0/24
NET_PORT=4713

COMBINE=yes              # sound-everywhere on by default (gamer preset)
COMBINE_SLAVES=          # empty = ALL sinks incl. HDMI; or list specific ones
```

To send sound to only some outputs (e.g. speakers + one HDMI, not all):
```
COMBINE_SLAVES=alsa_output.pci-..._Speaker__sink,alsa_output.pci-..._HDMI1__sink
```
Find the exact sink names with: `pactl list short sinks`.

---

## Good to know / gotchas

* **VT switching + Bluetooth.** When you switch away from your session, the
  Bluetooth stream is paused cleanly (no drone). When you switch back it
  reconnects; depending on the phone you may need to tap play once (some phones
  block remote resume). Plain speaker/HDMI audio is unaffected.
* **Media audio must be ON on the phone.** If a phone pairs but no sound comes
  through, check that "Media audio" is enabled for your box in the phone's
  Bluetooth device settings — that's the A2DP profile.
* **Group `audio` vs group `audiohub`.** These are different. `audiohub` is just
  a permission label for the hub. Don't confuse it with the system `audio`
  group.
* **One card, one active user.** Two different users logged in on one seat can't
  both hold the sound card at once — only the active session gets it. For a
  gaming rig with a single user this never comes up.
* **Turning it all off.** Set `HUB_MODE=no` and restart audiod — you're back to
  a plain, stock-behaving audio setup.

---

## Quick command cheat-sheet

```
audioctl hub status                 # what's going on
audioctl hub pair [seconds]         # pair a phone (PIN required)
audioctl hub play|pause|next|prev   # control the phone from your keyboard
audioctl hub reconnect              # pull Bluetooth back to you
audioctl hub combine [off]          # sound everywhere on/off
audioctl hub net                    # (re)apply network audio from config
audioctl status|restart             # your own PipeWire stack
```

Game on. 🎮🎧
