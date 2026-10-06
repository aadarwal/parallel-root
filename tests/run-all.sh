#!/usr/bin/env bash
# Every off-device suite, one line each; exits non-zero if any of them fails.
#
#   bash tests/run-all.sh        from any directory
#   bash tests/run-all.sh -v     the full output of every suite as well
#
# No phone is needed. The device half of test-displays.sh still runs only
# when PHONE_TEST_DEVICE names one (see that file).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
case "${1:-}" in
  -v|--verbose) VERBOSE=1 ;;
  "") ;;
  *) echo "usage: $0 [-v]" >&2; exit 2 ;;
esac

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/run-all.XXXXXX")"
trap 'rm -rf "$LOGS"' EXIT
failed=0

suite(){   # a name, then the command that runs it
  local name="$1" log rc last
  shift
  log="$LOGS/$name.log"
  "$@" > "$log" 2>&1
  rc=$?
  last="$(grep -v '^[[:space:]]*$' "$log" | tail -n 1)"
  if [ "$rc" -eq 0 ]; then
    printf 'ok    %-22s %s\n' "$name" "$last"
  else
    failed=1
    printf 'FAIL  %-22s %s (exit %d)\n' "$name" "$last" "$rc"
    # What failed, without the hundreds of lines that passed: the suites
    # mark failures with FAIL; anything else shows its last lines.
    if grep -q '^FAIL' "$log"; then
      grep '^FAIL' "$log" | sed 's/^/      /'
    else
      tail -n 15 "$log" | sed 's/^/      /'
    fi
  fi
  if [ "$VERBOSE" -eq 1 ]; then
    sed 's/^/    | /' "$log"
  fi
}

suite test-phone.sh        bash "$HERE/test-phone.sh"
suite test-displays.sh     bash "$HERE/test-displays.sh"
suite check-skill-verbs.py python3 "$HERE/check-skill-verbs.py"
exit "$failed"
