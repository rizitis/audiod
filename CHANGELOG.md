# Changelog

## 0.2.0 build 8 — Hub mode (party audio hub)

This release adds an optional **hub mode** that turns the machine into a party
audio hub, on top of the existing per-user audio session manager. Hub mode is
**off by default**; with `HUB_MODE=no` audiod behaves exactly as build 7, so
existing setups are unaffected.

### New: hub mode

* **Opt-in `HUB_MODE`.** All hub behaviour lives in a separate, sourced library
  (`/usr/libexec/audiod/hub.sh`) that is inert unless `HUB_MODE=yes`. The core
  reactor is unchanged except for two guarded hook calls.
* **Group-based permissions.** Only members of `HUB_GROUP` (default `audiohub`)
  get hub features; everyone else is ignored. If the group doesn't exist, nobody
  is allowed (safe default). The admin creates the group and adds members by
  hand, the Slackware way — the package never creates groups or users.

### New: Bluetooth speaker

* **Phones play through the box.** Paired phones stream audio (A2DP) to the
  box's speakers, mixed by PipeWire.
* **Bounded, on-demand pairing.** `audioctl hub pair [seconds]` opens a short
  discoverable window (default 120s) that you trigger. Pairing still requires
  the normal BlueZ PIN/confirmation — there is no blind auto-accept, and the box
  is never left permanently discoverable.
* **Trusted reconnect.** Paired devices are trusted so BlueZ reconnects them on
  its own.
* **Media control over AVRCP.** `audioctl hub play|pause|next|prev` drives the
  connected phone from the keyboard.

### New: VT-switch Bluetooth watcher

* **`hub-btwatch.sh`** — a per-owner background watcher (run under `daemon(1)`)
  that listens to elogind for active-session changes on the seat.
* When the owner **leaves** the active VT, it pauses the phone and suspends the
  Bluetooth stream **cleanly**, preventing the "tractor drone" that a mid-buffer
  A2DP cut would otherwise produce.
* When the owner **returns**, it reconnects and attempts to resume playback
  (best-effort; phones that block remote resume need one tap of play).
* Manual recovery is available any time with `audioctl hub reconnect`.

### New: combine output (sound everywhere)

* **`COMBINE`** mirrors playback to several outputs at once via a
  `hub_combined` sink, and makes it the default so everything you play lands on
  all chosen outputs automatically.
* Empty `COMBINE_SLAVES` includes **all** sinks — built-in speakers, every HDMI
  output, and any Bluetooth speaker. HDMI is included on purpose (gamers and AV
  setups want it). Restrict to specific outputs by listing sink names in
  `COMBINE_SLAVES`.
* Toggle live with `audioctl hub combine` / `audioctl hub combine off`.

### New: automatic hub ownership

* The card and the single system-wide Bluetooth adapter can only be held by one
  user at a time. The **first** hub member to log in automatically becomes the
  owner (recorded in `/run`, cleared on reboot); later members are kept from
  grabbing the shared adapter (their WirePlumber's bluez monitor is disabled).
* `HUB_OWNER` is an optional override to pin ownership to a specific user
  regardless of login order. Normally left empty — no configuration needed.

### New: network audio in (optional)

* **`NET_TCP`** lets trusted LAN machines stream to the box over TCP. Off by
  default and deny-by-default: `NET_TCP=yes` alone does nothing; an explicit
  `NET_ACL` allow-list is required. Never binds to the whole network implicitly.

### New: SlackBuild `GAME` switch

* `GAME=ON bash audiod.SlackBuild` ships the ready-to-go gamer/party preset as
  the default config (hub on, combine "sound everywhere" on). Without it, the
  normal conservative config is shipped (everything off by default).
* Both configs (`audiod.conf` and `audiod.conf.gamer`) live in `src/etc/audiod/`.

### Packaging

* Installs `hub.sh` (0644, sourced) and `hub-btwatch.sh` (0755, executable
  helper) under `/usr/libexec/audiod/`.
* Ships `README-hub.md` and the gamer guide in the docs.
* Passes `sbopkglint`.

### Security notes

* Hub mode opens the box up on purpose, so the defaults are conservative:
  Bluetooth pairing is bounded and PIN-gated, network audio is deny-by-default
  with a mandatory ACL, and only `audiohub` members can drive the hub. Clients
  allowed in via network audio can also see the owner's mic/monitors — only
  allow machines you trust, and keep the bind address local unless you mean it.

### Unchanged / compatibility

* With `HUB_MODE=no`, behaviour is identical to build 7: ordered PipeWire
  startup, readiness gating, per-user lifecycle, clean teardown, bus reuse.
* elogind remains unmodified. No systemd, no dinit, no new compiled daemon.

### Known limitations

* On VT switch, plain speaker/HDMI audio recovers on its own, but Bluetooth
  resume is best-effort and can depend on the phone (some block remote play).
* Two different local users cannot share one sound card simultaneously (a
  kernel/ALSA limit, identical under systemd). For cross-user sharing see the
  separate `audioshare` project.
