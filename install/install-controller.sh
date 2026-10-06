#!/usr/bin/env bash
# Put `phone` on PATH on a controller: a laptop or server that drives the
# phone over ssh.
#
#   bash install/install-controller.sh [--prefix DIR]
#
# Symlinks bin/phone from this checkout into DIR (default ~/.local/bin), so
# a `git pull` updates it. Replaces an existing symlink, and refuses to touch
# a regular file. Checks for python3 >= 3.8 and ssh, then prints an ssh
# config stanza for the phone and the first command to try.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)/bin/phone"
PREFIX_DIR="$HOME/.local/bin"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || { echo "install-controller: --prefix needs a directory" >&2; exit 2; }
      PREFIX_DIR="$2"; shift 2 ;;
    --prefix=*) PREFIX_DIR="${1#--prefix=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install-controller: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { printf 'install-controller: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ] || fail "no CLI at $SRC; run this from a clone of the repository"

# ---------------------------------------------------------------- python
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH (3.8 or later is needed)"
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
  fail "python3 is $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'); 3.8 or later is needed"
fi
say_py="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
echo "python3 $say_py"
command -v ssh >/dev/null 2>&1 || echo "warning: ssh is not on PATH; phone --device needs OpenSSH"

# ------------------------------------------------------------------ link
mkdir -p "$PREFIX_DIR" || fail "cannot create $PREFIX_DIR"
DEST="$PREFIX_DIR/phone"
chmod +x "$SRC" 2>/dev/null || true
if [ -L "$DEST" ]; then
  if [ "$(readlink "$DEST")" = "$SRC" ]; then
    echo "$DEST already points at $SRC"
  else
    ln -sfn "$SRC" "$DEST" || fail "cannot link $DEST"
    echo "relinked $DEST -> $SRC"
  fi
elif [ -e "$DEST" ]; then
  fail "$DEST exists and is not a symlink; move it aside, or use --prefix DIR"
else
  ln -s "$SRC" "$DEST" || fail "cannot link $DEST"
  echo "linked $DEST -> $SRC"
fi

case ":$PATH:" in
  *":$PREFIX_DIR:"*) ;;
  *) echo
     echo "$PREFIX_DIR is not on PATH. Add it in your shell profile:"
     echo "  export PATH=\"$PREFIX_DIR:\$PATH\"" ;;
esac

cat <<'NEXT'

Add the phone to ~/.ssh/config. The alias must be lowercase:

  Host my-phone
      HostName <phone-ip-or-name>
      Port 8022
      IdentityFile ~/.ssh/id_ed25519

Connect once by hand so the host key is recorded (phone uses BatchMode):

  ssh my-phone true

Then:

  phone --device my-phone capabilities

To skip --device, set PHONE_DEVICE=my-phone in the environment or in
~/.config/parallel-root/config. See docs/configuration.md.
NEXT
