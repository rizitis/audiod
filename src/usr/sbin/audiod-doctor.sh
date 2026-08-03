#!/bin/bash
# audiod-doctor.sh -- repair what a pipewire/pulseaudio upgrade breaks.
#
# WHAT IT FIXES
# -------------
# Three things, all of which come back on their own and all of which fail
# silently -- audio keeps working, audiod reports success, and only the hub
# quietly stops existing:
#
#   1. /etc/xdg/autostart/pulseaudio.desktop reinstalled by an upgrade. At the
#      next login it starts a real PulseAudio daemon, which grabs
#      /run/user/UID/pulse/native before pipewire-pulse can. Every pactl call
#      then lands in the wrong server.
#
#   2. ~/.config/pulse/client.conf without an autospawn setting. libpulse uses
#      the per-user file INSTEAD of /etc/pulse/client.conf -- not merged -- so
#      a system-wide 'autospawn = no' silently stops applying and any client
#      may spawn PulseAudio. An almost-empty user file is enough to do this.
#
#   3. A PulseAudio daemon already running next to PipeWire.
#
# It also reports unmerged *.new config files, but does NOT merge them: which
# side of a config diff you want is a judgement call, not a script's business.
#
# SAFETY
# ------
# Refuses to touch anything on a system that is genuinely in PulseAudio mode;
# disabling Pulse there would leave no audio at all. Never deletes: files are
# renamed, and client.conf is backed up before being edited. Idempotent, so
# running it twice is harmless.
#
# Usage:
#   audiod-doctor.sh            fix what is broken
#   audiod-doctor.sh --check    report only, change nothing
#
# Exit: 0 = nothing to do (or all repaired), 1 = problems remain / found in
#       --check mode, 2 = refused to act.

CHECK=0
case "$1" in
    --check|-n) CHECK=1 ;;
    --help|-h)  sed -n '2,36p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    "")         ;;
    *)          echo "audiod-doctor: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac

AUTOSTART_DIR="${AUDIOD_AUTOSTART_DIR:-/etc/xdg/autostart}"
FOUND=0
FIXED=0

say()   { printf '%s\n' "$*"; }
found() { printf '  [!] %s\n' "$*"; FOUND=$((FOUND + 1)); }
fixed() { printf '  [+] %s\n' "$*"; FIXED=$((FIXED + 1)); }
okay()  { printf '  [ok] %s\n' "$*"; }
note()  { printf '       %s\n' "$*"; }

need_root() {
    [ "$(id -u)" = 0 ] && return 0
    note "needs root: sudo $0"
    return 1
}

# --- refuse on a genuine PulseAudio system ---------------------------------
# Slackware's pipewire-enable.sh / pipewire-disable.sh switch servers by
# renaming the autostart entries: in PulseAudio mode pipewire.desktop is
# renamed to pipewire.desktop.sample. Disabling Pulse there would leave
# nothing starting audio at all.
if [ ! -x /usr/bin/pipewire ]; then
    say "audiod-doctor: PipeWire is not installed; nothing to do."
    exit 2
fi
if [ -e "$AUTOSTART_DIR/pulseaudio.desktop" ] && \
   [ ! -e "$AUTOSTART_DIR/pipewire.desktop" ]; then
    say "audiod-doctor: this system is in PulseAudio mode (pipewire.desktop is"
    say "sampled out). Refusing to act -- switch to PipeWire first with"
    say "Slackware's pipewire-enable.sh, then re-run."
    exit 2
fi

if [ "$CHECK" = 1 ]; then
    say "audiod-doctor: check only, nothing will be changed"
    say ""
fi

# ---------------------------------------------------------------------------
say "1. XDG autostart"
d="$AUTOSTART_DIR/pulseaudio.desktop"
if [ ! -e "$d" ]; then
    okay "pulseaudio.desktop not present"
elif grep -q '^Hidden=true$' "$d" 2>/dev/null; then
    okay "pulseaudio.desktop present but hidden"
else
    found "pulseaudio.desktop is ACTIVE -- it will start PulseAudio at next login"
    note "an upgrade reinstalled it"
    if [ "$CHECK" = 0 ] && need_root; then
        # Rename rather than delete, and never clobber an earlier .disabled:
        # a second upgrade would otherwise overwrite the copy we saved first.
        target="$d.disabled"
        n=1
        while [ -e "$target" ]; do target="$d.disabled.$n"; n=$((n + 1)); done
        if mv "$d" "$target"; then
            fixed "moved to $(basename "$target")"
        else
            note "could not move $d"
        fi
    fi
fi

# ---------------------------------------------------------------------------
say ""
say "2. per-user client.conf"
# Check every ordinary user with a home, not just the caller: audiod serves
# all of them, and one shadowed file is enough to cause trouble.
while IFS=: read -r u _ uid _ _ home _; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] || continue
    [ "$uid" -lt 65000 ] || continue
    [ -d "$home" ] || continue
    f="$home/.config/pulse/client.conf"
    if [ ! -e "$f" ]; then
        okay "$u: no per-user client.conf (the system one applies)"
        continue
    fi

    if grep -Eq '^[[:space:]]*autospawn[[:space:]]*=' "$f"; then
        val=$(sed -n 's/^[[:space:]]*autospawn[[:space:]]*=[[:space:]]*//p' "$f" \
              | sed 's/[[:space:]]*[;#].*$//; s/[[:space:]]*$//' | tail -1)
        case "$val" in
            no|false|off|0)
                okay "$u: client.conf sets autospawn = $val"
                ;;
            *)
                found "$u: client.conf sets autospawn = $val (PulseAudio may spawn)"
                if [ "$CHECK" = 0 ] && need_root; then
                    cp -p "$f" "$f.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null
                    if sed -i 's/^[[:space:]]*autospawn[[:space:]]*=.*/autospawn = no/' "$f"; then
                        fixed "$u: set autospawn = no (backup kept)"
                    fi
                fi
                ;;
        esac
    else
        found "$u: client.conf exists but sets no autospawn -> libpulse defaults to YES"
        note "this file SHADOWS /etc/pulse/client.conf entirely"
        if [ "$CHECK" = 0 ] && need_root; then
            cp -p "$f" "$f.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null
            if {
                echo ""
                echo "# added by audiod-doctor: this per-user file REPLACES"
                echo "# /etc/pulse/client.conf rather than merging with it, so the"
                echo "# system-wide setting has to be repeated here."
                echo "autospawn = no"
            } >> "$f"; then
                fixed "$u: appended autospawn = no (backup kept)"
            fi
        fi
    fi
done < /etc/passwd

# ---------------------------------------------------------------------------
say ""
say "3. running PulseAudio daemon"
if pgrep -x pulseaudio >/dev/null 2>&1; then
    found "a PulseAudio daemon is running alongside PipeWire"
    pgrep -a -x pulseaudio | sed 's/^/       /'
    if [ "$CHECK" = 0 ]; then
        # Deliberately not automatic: killing it drops audio for whoever is
        # using it right now, and with autospawn still live it may come
        # straight back and grab the socket again.
        note "not killed automatically -- that would drop audio mid-session"
        note "with the fixes above in place, log out and back in;"
        note "or stop it now with:  pulseaudio --kill"
    fi
else
    okay "no PulseAudio daemon running"
fi

# ---------------------------------------------------------------------------
say ""
say "4. unmerged config files"
n=0
for f in /etc/pulse/*.new /etc/pulse/*/*.new \
         /etc/pipewire/*.new /etc/pipewire/*/*.new \
         /etc/audiod/*.new /etc/rc.d/rc.audiod.new; do
    [ -e "$f" ] || continue
    say "  [.] $f"
    n=$((n + 1))
done
if [ "$n" = 0 ]; then
    okay "none waiting"
else
    note "not merged automatically -- review these yourself"
    note "(an upgrade may have changed defaults audiod reasons about)"
fi

# ---------------------------------------------------------------------------
say ""
if [ "$FOUND" = 0 ]; then
    say "Nothing to fix."
    exit 0
fi
if [ "$CHECK" = 1 ]; then
    say "$FOUND problem(s) found. Re-run without --check to fix."
    exit 1
fi
say "$FIXED of $FOUND problem(s) fixed."
if [ "$FIXED" -lt "$FOUND" ]; then
    say "Some need root or manual attention -- see the notes above."
    exit 1
fi
say "Log out and back in for the changes to take effect."
exit 0
