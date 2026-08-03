# Changelog


## 3.0 — the hub now actually survives

A debugging session on a live Slackware64-current box turned up six independent
faults, each on its own enough to stop hub mode from working, and each silent:
audio kept playing, `audiod` reported success, and only the hub quietly failed
to exist. They are listed in the order they were found, because each one was
hiding the next.

### Fixed: `audioctl hub status` reported the configuration, not the system

The status output printed the variables from `audiod.conf`. `COMBINE: yes` meant
"yes is written in the config file", not "the sink exists". `hub_is_owner`
returned true when nobody had claimed ownership at all, and `hub_release_owner`
empties that state on logout — so after the first logout every user displayed as
OWNER, forever.

The practical effect was worse than a cosmetic bug: a hub that had never come up
looked identical to a working one, which is why the underlying faults went
unnoticed for so long.

Every runtime line is now a live query — PipeWire for the combine sink, BlueZ
for Bluetooth, the state file for ownership, the process table for the watchers
— and prints `<-- mismatch` where configuration and reality disagree.
`hub_is_owner` gained a third return value for "unclaimed".

### Fixed: a foreign combine module silently disabled ours

`hub_combine_init` skipped its work if `pactl list short modules` matched
`module-combine-sink` anywhere. Any stale or third-party combine module — for
instance one loaded with no arguments from a config drop-in — satisfied that
test, so the function logged "combine-sink already present" and returned
success without creating `hub_combined`. The `set-default-sink` that followed
failed into `/dev/null`.

It now tests for *our* sink by name. `hub_combine_off` likewise targets the
module whose argument is `sink_name=hub_combined` rather than the first combine
module it finds, so a stale one is no longer unloaded in its place.

### Fixed: the combine sink was built before any sink existed

`hub_start` runs immediately after `start_stack`, and `stack.conf` gates only
PipeWire's own socket — `wireplumber` and `pipewire-pulse` start with no
readiness check. At boot the combine sink was therefore created over an *empty*
sink set, roughly a second before WirePlumber published the card. A combine sink
with no members does not survive, so it was logged as "created and set as
default" and then vanished. Interactively the gap never showed, because by then
the card had long been up.

Two gates were added: `hub_pulse_ready` waits for `pactl` to answer, and
`hub_sinks_ready` waits for a real sink to appear (ignoring `auto_null`, which
is what PipeWire publishes when it has no device). If none appears within
`COMBINE_WAIT` seconds, no sink is created and the log says why. `pactl`'s own
error output is no longer discarded, and the log now records how many outputs
the mix was built over, so an empty one is visible at a glance.

### New: `hub-pulsewatch.sh`

`hub_combined` and the network-audio module are loaded *into* `pipewire-pulse`
and die with it. The supervisor then restarts the service, so the stack looks
perfectly healthy afterwards — all three daemons running, audio working — while
the hub is gone. No login1 signal is raised by a service restart, so nothing
rebuilt it: the hub stayed missing until the next real login.

A per-owner watcher now notices the pulse server was replaced and re-applies the
owner's extras. It is idempotent, and it respects a deliberate
`audioctl hub combine off` — that choice is recorded in
`/run/user/$uid/audiod-hub-combine` so the watcher does not undo it. Controlled
by `HUB_PULSEWATCH_ENABLE` and `HUB_PULSEWATCH_INTERVAL`.

### Fixed: `reconcile` ran once, before the signal stream was attached

Any `UserNew` raised while the stream was down was lost for good — the reconnect
re-attached but never asked who was logged in. Running reconcile *before*
attaching left the same hole at startup: audiod reconciled an empty user list at
boot and only attached seconds later, so a login inside that window fell through
both mechanisms.

Reconcile now runs on every connect, and after the stream is attached rather
than before, closing the window from both sides. A repeat no longer reports a
login that did not happen.

### Fixed: nothing started at boot for a lingering user

The root cause of "hub never comes up after a reboot, but `rc.audiod restart`
fixes it". `UserNew` fires when the *user object* is created, not when a session
starts. With `loginctl enable-linger` that object is created at boot, before
anybody logs in — so the graphical login raises `SessionNew` and **no `UserNew`
at all**. Meanwhile reconcile at boot found the user, found no seat session yet,
and gave up via `dbg`, which is silent under the default `DEBUG=no`.

`SessionNew` and `SessionRemoved` are now handled alongside the user signals.
The handlers are idempotent, so whichever arrives first takes effect;
`SessionRemoved` tears down only once the user has no local seated session left.
Reconcile also says out loud, once per uid, when it declines to start a stack.

### Fixed: `is_pipewire_mode` read a `client.conf` that libpulse ignores

It consulted `/etc/pulse/client.conf`. libpulse uses the first main file that
exists — `$PULSE_CLIENTCONFIG`, then `~/.config/pulse/client.conf`, then the
system file — and the per-user file **replaces** the system one rather than
merging with it. A per-user file containing nothing but a commented-out
`default-sink` was therefore enough to discard a system-wide `autospawn = no`
and leave libpulse's default of `yes` in force.

The consequence was the original fault behind this whole release: PulseAudio
autospawned at login and bound `/run/user/$uid/pulse/native` before
`pipewire-pulse` could. Every `pactl` call then landed in PulseAudio while
WirePlumber and `coppwr` saw a different graph — so `hub_combined` was created
in the wrong server and never appeared. Which server won was a race, which is
why it worked on some boots and not others.

Resolution now follows libpulse's own order, including `client.conf.d/`
drop-ins, with the layering precedence they actually use.

### New: `audiod-doctor.sh`

Repairs the two conditions that recreate themselves. A pulseaudio package
upgrade reinstates `/etc/xdg/autostart/pulseaudio.desktop` (observed once
already: the `.sample` was dated 29 June, the reinstated `.desktop` 3 July), and
a per-user `client.conf` can be created by any desktop sound applet.

It moves an active `pulseaudio.desktop` aside — never deletes, and never
clobbers an earlier `.disabled` — and adds `autospawn = no` to a shadowing
per-user `client.conf`, keeping a timestamped backup. It checks every user with
a uid ≥ 1000, not just the caller. `--check` reports without changing anything.

It deliberately does *not* kill a running PulseAudio daemon (that would drop
audio mid-session) or merge `*.new` config files (which side of a config diff
you want is a judgement call). It refuses outright on a system genuinely in
PulseAudio mode, where disabling Pulse would leave no audio at all.

### Documentation

`README.md`, `README-audiod.md`, `README-hub.md`, `GAMER-GUIDE.md`,
`COMBINE-EXAMPLE.md`, `audiod.8` and `audioctl.1` updated. `audiod.8` gains a
DIAGNOSTICS section for the "sound works but the hub is gone" symptom, which is
the recognisable signature of `pactl` and `wpctl` talking to different servers.
The stale `hub status` example in `COMBINE-EXAMPLE.md` was replaced.

### Known limitations (unchanged, now documented)

* **The combine sink is static.** It mirrors to the outputs that existed when it
  was created. Sources come and go freely — a new phone joins the mix instantly
  — but a new *output* does not; connect Bluetooth speakers before building the
  mix, or rebuild it. Following new sinks dynamically needs the native
  `module-combine-stream` with `stream.rules` instead of the PulseAudio
  compatibility module. Not done.
* **A microphone near loud speakers will howl.** Combine plays through the
  built-in speakers *and* the Bluetooth ones, and a laptop mic array sits
  centimetres from the former. Acoustic feedback while the hub is loud is
  physics, not a fault.

### Compatibility

With `HUB_MODE=no` behaviour is unchanged. elogind remains unmodified.

---


## 1.0.3 adapt to pipewire 1.6.8-2: profile.d starters are opt-in now

restore.sh no longer chmod +x's them (stock ships them non-executable);
is_pipewire_mode no longer reads "autospawn = yes" as PulseAudio when
daemon-binary is pipewire-start; takeover comments updated for the removed
wireplumber/pipewire-pulse desktop files. Coexistence is unchanged --
pipewire-start shares audiod's ~/.run/--name convention and idempotency
check, so PipeWire is never double-started.

---


## 0.2.x build — Hub mode (party audio hub)

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
