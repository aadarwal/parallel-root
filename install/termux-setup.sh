#!/usr/bin/env bash
# Set up the phone side of parallel-root. Runs inside Termux on Android.
#
#   bash install/termux-setup.sh [--watchdog] [PATH-TO-phone]
#
# Safe to run again: each step checks before it acts, and nothing is ever
# deleted. A changed `phone` is copied over the old one only after the old
# one has been kept as phone.prev.
#
# What it does, in order:
#   1. installs python, openssh and termux-api if any is missing
#   2. copies bin/phone (from this checkout, or PATH-TO-phone) to
#      ~/.local/bin/phone, and links it into $PREFIX/bin so that commands run
#      over ssh find it
#   3. puts ~/.local/bin on PATH and exports TMPDIR and RISH_APPLICATION_ID in
#      ~/.profile, once, under a marker comment
#   4. starts sshd and prints the port and how to add a key
#   5. checks ~/rish and ~/rish_shizuku.dex, and starts the shell daemon when
#      rish answers
#   6. with --watchdog, registers the watchdog with JobScheduler
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG=0
SRC=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --watchdog) WATCHDOG=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "termux-setup: unknown option $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$SRC" ]; then
        echo "termux-setup: one path to phone at most" >&2; exit 2
      fi
      SRC="$arg" ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '!  %s\n' "$*"; }

# ------------------------------------------------------------ inside Termux?
# Termux's prefix lives under the app's data directory. Anywhere else this
# script would install into the wrong place, so it stops.
case "${PREFIX:-}" in
  */com.termux/*) in_termux=1 ;;
  *) in_termux=0 ;;
esac
if [ "$in_termux" != 1 ] || ! command -v pkg >/dev/null 2>&1; then
  say "This script sets up the phone, and it runs inside Termux on Android."
  say "Nothing was changed."
  say "On a controller (a laptop or server), run install/install-controller.sh."
  exit 1
fi

if [ -z "$SRC" ]; then
  SRC="$HERE/../bin/phone"
fi
if [ ! -f "$SRC" ]; then
  say "No phone CLI at $SRC."
  say "Run this from a clone of the repository, or pass the path to bin/phone."
  exit 1
fi
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
if ! head -n 1 "$SRC" | grep -q python; then
  say "$SRC does not look like the phone CLI (no python on its first line)."
  exit 1
fi

BIN="$HOME/.local/bin"
DEST="$BIN/phone"

# ---------------------------------------------------------------- packages
step "packages"
missing=""
command -v python3 >/dev/null 2>&1 || missing="$missing python"
command -v sshd >/dev/null 2>&1 || missing="$missing openssh"
command -v termux-battery-status >/dev/null 2>&1 || missing="$missing termux-api"
if [ -n "$missing" ]; then
  say "installing:$missing"
  if ! pkg install -y python openssh termux-api; then
    warn "pkg install failed. Run 'pkg update' and try again."
    exit 1
  fi
else
  say "python, openssh and termux-api are installed"
fi
say "termux-api also needs the Termux:API app, from the same source as Termux."

# --------------------------------------------------------------- the CLI
step "phone CLI"
mkdir -p "$BIN"
if [ -e "$DEST" ] && cmp -s "$SRC" "$DEST"; then
  say "$DEST is up to date"
else
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    cp -P "$DEST" "$DEST.prev"
    say "kept the previous copy as $DEST.prev"
  fi
  cp "$SRC" "$DEST.new" && chmod 755 "$DEST.new" && mv "$DEST.new" "$DEST"
  say "installed $DEST"
fi

# A command run over ssh gets Termux's default PATH, which has $PREFIX/bin
# but not ~/.local/bin. The controller runs `phone` on the phone that way, so
# a link in $PREFIX/bin is what makes it found.
LINK="$PREFIX/bin/phone"
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$DEST" ]; then
  say "$LINK points at $DEST"
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  warn "$LINK exists and is not a link to $DEST; left alone."
  warn "Remove it yourself, or set PHONE_REMOTE_BIN=$DEST on the controller."
else
  ln -s "$DEST" "$LINK"
  say "linked $LINK -> $DEST"
fi

# --------------------------------------------------------------- profile
step "shell profile"
PROFILE="$HOME/.profile"
MARK="# parallel-root: PATH, TMPDIR and rish (added by install/termux-setup.sh)"
if [ -f "$PROFILE" ] && grep -qF "$MARK" "$PROFILE"; then
  say "$PROFILE already has the parallel-root block"
else
  # An app uid cannot write /tmp on Android, even at mode 0777: SELinux, not
  # Unix permissions. TMPDIR has to point into Termux's own prefix in every
  # shell that runs phone.
  {
    printf '\n%s\n' "$MARK"
    cat <<'PROFILE_BLOCK'
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
export TMPDIR="$PREFIX/tmp"
export RISH_APPLICATION_ID=com.termux
# end parallel-root
PROFILE_BLOCK
  } >> "$PROFILE"
  say "added PATH, TMPDIR and RISH_APPLICATION_ID to $PROFILE"
fi
for f in "$HOME/.bash_profile" "$HOME/.bash_login"; do
  if [ -f "$f" ] && ! grep -q '\.profile' "$f"; then
    warn "bash reads $f instead of ~/.profile for login shells."
    warn "Add this line to it:  . ~/.profile"
  fi
done
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) export PATH="$BIN:$PATH" ;;
esac
export TMPDIR="$PREFIX/tmp"

# ------------------------------------------------------------------ sshd
step "sshd"
SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config"
sshd_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x sshd >/dev/null 2>&1
  else
    return 1
  fi
}
if sshd_running; then
  say "sshd is running"
elif sshd 2>/dev/null; then
  say "started sshd"
elif sshd_running || ! command -v pgrep >/dev/null 2>&1; then
  say "sshd did not start; it may already be running"
else
  warn "sshd did not start. Run 'sshd -d' to see why."
fi
PORT=""
if [ -f "$SSHD_CONFIG" ]; then
  PORT="$(awk 'tolower($1) == "port" { print $2; exit }' "$SSHD_CONFIG")"
fi
PORT="${PORT:-8022}"
say "port: $PORT (Termux ignores the user name; any name logs in as this app)"

AUTH="$HOME/.ssh/authorized_keys"
keys=0
if [ -f "$AUTH" ]; then
  keys="$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$AUTH" || true)"
fi
if [ "${keys:-0}" -gt 0 ]; then
  say "$AUTH holds $keys key(s)"
else
  say "No authorized keys yet. Copy the controller's public key"
  say "(~/.ssh/id_ed25519.pub) to this phone's clipboard, then run:"
  say "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  say "  termux-clipboard-get >> ~/.ssh/authorized_keys"
  say "  chmod 600 ~/.ssh/authorized_keys"
fi
if [ -f "$SSHD_CONFIG" ] && \
   grep -Eiq '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHD_CONFIG"; then
  say "password logins are off"
else
  warn "Password logins are still allowed. Once a key works, add these lines to"
  warn "$SSHD_CONFIG and restart sshd (pkill sshd; sshd):"
  warn "  PasswordAuthentication no"
  warn "  KbdInteractiveAuthentication no"
fi
say "Reach this port only over a private network (Tailscale or your LAN)."

# ---------------------------------------------------------------- Shizuku
step "Shizuku (rish)"
RISH="$HOME/rish"
DEX="$HOME/rish_shizuku.dex"
rish_ok=0
if [ ! -f "$RISH" ] || [ ! -f "$DEX" ]; then
  say "~/rish and ~/rish_shizuku.dex are not both here. To export them:"
  say "  1. Start Shizuku through wireless debugging (Android 11 and later)."
  say "  2. In Shizuku: 'Use Shizuku in terminal apps', then 'Export files',"
  say "     into a folder on shared storage."
  say "  3. In Termux:"
  say "       termux-setup-storage"
  say "       cp ~/storage/shared/<folder>/rish ~/storage/shared/<folder>/rish_shizuku.dex ~/"
  say "  4. Run this script again."
  say "Without them, phone works only for termux-api verbs (no screen, no shell)."
else
  [ -x "$RISH" ] || { chmod 700 "$RISH"; say "made ~/rish executable"; }
  # rish refuses to load a dex that is writable on recent Android.
  if [ -w "$DEX" ]; then
    chmod 400 "$DEX"
    say "made ~/rish_shizuku.dex read-only"
  fi
  say "asking rish for a shell. If Shizuku asks whether Termux may use it, allow it."
  if command -v timeout >/dev/null 2>&1; then
    RISH_APPLICATION_ID=com.termux timeout 30 "$RISH" -c true >/dev/null 2>&1 \
      && rish_ok=1
  else
    RISH_APPLICATION_ID=com.termux "$RISH" -c true >/dev/null 2>&1 && rish_ok=1
  fi
  if [ "$rish_ok" = 1 ]; then
    say "rish answers"
  else
    warn "rish did not answer. Open Shizuku and check that it is running"
    warn "(it stops at every reboot) and that Termux is authorised."
  fi
fi

# ------------------------------------------------------------ shell daemon
step "shell daemon"
if [ "$rish_ok" = 1 ]; then
  "$DEST" shelld --start || warn "phone shelld --start failed"
else
  say "skipped: start it with 'phone shelld --start' once rish answers"
fi

# --------------------------------------------------------------- watchdog
step "watchdog"
if [ "$WATCHDOG" = 1 ]; then
  if command -v termux-job-scheduler >/dev/null 2>&1; then
    "$DEST" watchdog --install || warn "phone watchdog --install failed"
  else
    warn "termux-job-scheduler is missing; install termux-api and the Termux:API app"
  fi
else
  say "not registered. Run this script with --watchdog, or 'phone watchdog --install',"
  say "so sshd and the shell daemon come back after Android reaps them."
fi

# ------------------------------------------------------------- next steps
step "next"
say "1. Open a new Termux session, or run:  . ~/.profile"
say "2. phone capabilities"
say "3. On the controller, add an ssh host for this phone:"
say "     Host my-phone"
say "         HostName <phone-ip-or-name>"
say "         Port $PORT"
say "   then: phone --device my-phone capabilities"
say "4. For phone display create, stage the display holder (docs/setup.md, step 8)."
