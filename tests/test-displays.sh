#!/usr/bin/env bash
# Multi-display: one phone, several screens, one driver each.
#
# Two halves. The first runs anywhere — the tree merging, the device-side
# filter, the flag threading, the holder's names, the per-display lease and
# the lanes all work against fixtures and a local `sh` daemon, because that is
# where the logic is. The second half needs a phone and runs only when
# PHONE_TEST_DEVICE names one:
#
#   PHONE_TEST_DEVICE=<ssh-host> bash tests/test-displays.sh
#
# It releases only the displays it created, by id, and never touches display
# 0 beyond reading it. The two steps that would put something on the
# person's own screen — `display move --to 0` and `display create --visible`
# — run only with PHONE_TEST_INTRUSIVE=1 as well.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHONE="$HERE/bin/phone"
# /tmp, not $TMPDIR: the local daemons listen on unix sockets in here, and a
# long TMPDIR pushes a socket path past the 104-byte limit.
T="$(mktemp -d /tmp/phone-display-test.XXXXXX)"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$*"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }

# The device half's settings are the caller's to choose: which phone, whether
# to intrude, the lane to drive in (so a test run does not queue behind other
# agents' commands) and the name of the CLI on the phone. Everything else in
# the caller's PHONE_* environment stays out — an exported PHONE_DEVICE
# alone would point the local daemons below at a real phone.
for v in $(compgen -e); do
  case "$v" in
    PHONE_TEST_DEVICE|PHONE_TEST_INTRUSIVE|PHONE_LANE|PHONE_REMOTE_BIN) ;;
    PHONE_*) unset "$v" ;;
  esac
done
export PHONE_CONFIG="$T/no-such-config"
export PHONE_LEDGER="$T/ledger.jsonl"
export PHONE_RISH="$T/no-rish"
ORIG_PREFIX="${PREFIX-}"
export PREFIX="$T/prefix"
# The module imports below must not leave a bytecode cache in the checkout.
export PYTHONDONTWRITEBYTECODE=1
# No real host and no real adb for the off-device half; the device half gets
# the caller's PATH back.
ORIG_PATH="$PATH"
NODEV="$T/nodev"; mkdir -p "$NODEV"
printf '#!/bin/sh\necho "ssh: the off-device half never reaches a host" >&2\nexit 255\n' > "$NODEV/ssh"
printf '#!/bin/sh\n[ "$1" = devices ] && { printf "List of devices attached\\n\\n"; exit 0; }\nexit 1\n' > "$NODEV/adb"
chmod +x "$NODEV/ssh" "$NODEV/adb"
export PATH="$NODEV:$PATH"

DEV="${PHONE_TEST_DEVICE:-}"
CREATED=""            # display ids the device half made, and has not released
release(){            # release ONE display this run created, by its id
  if env -u PHONE_SHELL_SOCK -u PHONE_SHELL_ARGV \
       "$PHONE" --device "$DEV" display rm "$1" >/dev/null 2>&1; then
    CREATED="$(for x in $CREATED; do [ "$x" = "$1" ] || printf '%s ' "$x"; done)"
    return 0
  fi
  return 1
}
cleanup(){
  # Only what this run started: the local daemons by their own sockets, and
  # the displays it created by their ids. Never `display rm --all` — that
  # would also clear overlay displays somebody else made.
  for s in "$T/shell.sock" "$T/tmp/phone-shell-alpha.sock" \
           "$T/tmp/phone-shell-beta.sock"; do
    [ -S "$s" ] && PHONE_SHELL_SOCK="$s" "$PHONE" shelld --stop >/dev/null 2>&1
  done
  if [ -n "$DEV" ]; then
    for id in $CREATED; do release "$id"; done
  fi
  rm -rf "$T"
}
trap cleanup EXIT

# Load `phone` as a module. It has no .py suffix and is meant to stay one
# file (the device runs a single deployed copy, not a checkout), so the
# import is by path.
py(){ PHONE_PATH="$PHONE" python3 - "$@"; }
PRELUDE='
import importlib.util, importlib.machinery, os, sys
spec = importlib.util.spec_from_loader(
    "phonemod", importlib.machinery.SourceFileLoader(
        "phonemod", os.environ["PHONE_PATH"]))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
'

# A --windows dump with two displays. Window order is TOP-FIRST, as the real
# thing produces it: the status bar (layer 1) before the app (layer 0).
cat > "$T/win.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><displays><display id="0"><window index="0" title="" bounds="[0,0][1080,63]" active="false" focused="false" id="1" layer="1" type="TYPE_SYSTEM"><hierarchy rotation="0"><node index="0" text="statusbar-zero" resource-id="" class="android.widget.FrameLayout" package="com.android.systemui" content-desc="" clickable="false" enabled="true" bounds="[0,0][1080,63]" /></hierarchy></window><window index="1" title="" bounds="[0,0][1080,2400]" active="true" focused="true" id="2" layer="0" type="TYPE_APPLICATION"><hierarchy rotation="0"><node index="0" text="launcher-zero" resource-id="" class="android.widget.FrameLayout" package="com.google.android.apps.nexuslauncher" content-desc="" clickable="true" enabled="true" bounds="[0,0][1080,2400]" /></hierarchy></window></display><display id="7"><window index="0" title="" bounds="[0,0][1080,63]" active="false" focused="false" id="3" layer="1" type="TYPE_SYSTEM"><hierarchy rotation="0"><node index="0" text="statusbar-seven" resource-id="" class="android.widget.FrameLayout" package="com.android.systemui" content-desc="" clickable="false" enabled="true" bounds="[0,0][1080,63]" /></hierarchy></window><window index="1" title="" bounds="[0,0][1080,2400]" active="true" focused="true" id="4" layer="0" type="TYPE_APPLICATION"><hierarchy rotation="0"><node index="0" text="calendar-seven" resource-id="" class="android.widget.FrameLayout" package="com.google.android.calendar" content-desc="" clickable="true" enabled="true" bounds="[0,0][1080,2400]" /></hierarchy></window></display></displays>
XML

# ---------------------------------------------------------------- merging
out="$(py <<PY
$PRELUDE
x = open("$T/win.xml").read()
h = m._hierarchy_for_display(x, 7)
print("root_ok" if h.startswith("<hierarchy") else "root_bad")
print("has_seven" if "calendar-seven" in h else "no_seven")
print("no_zero" if "launcher-zero" not in h else "leaked_zero")
PY
)"
[ "$(echo "$out" | sed -n 1p)" = "root_ok" ] && ok "merge yields a <hierarchy> root" || bad "merge root: $out"
echo "$out" | grep -q has_seven && ok "merge keeps the asked-for display" || bad "merge lost display 7"
echo "$out" | grep -q no_zero && ok "merge excludes every other display" || bad "merge leaked display 0"

# The ordering is the whole reason this function exists: readers below it
# treat a LATER sibling as drawn on top, and --windows lists windows the
# other way round. Status bar (layer 1) must end up AFTER the app.
out="$(py <<PY
$PRELUDE
h = m._hierarchy_for_display(open("$T/win.xml").read(), 7)
print("bottom_first" if h.index("calendar-seven") < h.index("statusbar-seven")
      else "top_first")
PY
)"
[ "$out" = "bottom_first" ] && ok "windows merge bottom-first (occlusion stays sane)" \
  || bad "window order is $out — topmost_clickable_at would invert"

# A plain single-display dump has to pass through untouched.
out="$(py <<PY
$PRELUDE
plain = '<hierarchy rotation="0"><node index="0" text="x" /></hierarchy>'
print("passthrough" if m._hierarchy_for_display(plain, 0) == plain else "mangled")
PY
)"
[ "$out" = "passthrough" ] && ok "a single-display dump is left alone" || bad "passthrough: $out"

# --------------------------------------------------------- device filter
# The sed has to survive a real shell and cut exactly one display out of a
# one-line document — this is what keeps the read under the corruption
# threshold, so it is not cosmetic.
filter="$(py <<PY
$PRELUDE
print(m.display_filter("$T/win.xml", 7))
PY
)"
# sed emits a trailing newline, so compare with whitespace squeezed out —
# the XML is valid either way and the merger below proves it parses.
got="$(eval "$filter" 2>/dev/null)"
flat="$(printf '%s' "$got" | tr -d '\n')"
case "$flat" in
  "<displays><display id=\"7\">"*"</display></displays>") ok "device filter brackets one display" ;;
  *) bad "device filter produced: ${flat:0:90}" ;;
esac
echo "$got" | grep -q calendar-seven && ok "device filter keeps display 7's tree" || bad "filter dropped 7"
if [ -z "$got" ]; then bad "device filter produced nothing"
elif echo "$got" | grep -q launcher-zero; then bad "filter leaked display 0"
else ok "device filter drops display 0"; fi
# And what it emits must be what the merger accepts.
out="$(printf '%s' "$got" > "$T/filtered.xml"; py <<PY
$PRELUDE
h = m._hierarchy_for_display(open("$T/filtered.xml").read(), 7)
print("chains" if "calendar-seven" in h else "broken")
PY
)"
[ "$out" = "chains" ] && ok "filter output feeds the merger" || bad "filter/merger mismatch: $out"

# ----------------------------------------------------------- flag shapes
out="$(py <<PY
$PRELUDE
m._DISPLAY[0] = 0
print("input[%s] am[%s]" % (m._dflag(), m._amflag()))
m._DISPLAY[0] = 4
print("input[%s] am[%s]" % (m._dflag(), m._amflag()))
PY
)"
[ "$(echo "$out" | sed -n 1p)" = "input[] am[]" ] \
  && ok "display 0 issues byte-identical commands" || bad "display 0 flags: $out"
[ "$(echo "$out" | sed -n 2p)" = "input[ -d 4] am[ --display 4]" ] \
  && ok "input takes -d, am start takes --display" || bad "display 4 flags: $out"

# `type` counts delivered characters from the plan, not from a string
# prefix — the prefix stopped matching once a flag went in front of `text`.
out="$("$PHONE" --display 4 type --print-only "ab cd" 2>&1)"
echo "$out" | grep -q -- "input -d 4 text ab" && ok "type carries the display" \
  || bad "type plan: $out"
echo "$out" | grep -q -- "input -d 4 keyevent 62" && ok "the space keyevent carries it too" \
  || bad "type space: $out"

# ----------------------------------------------- what is in front, per display
# resumed_probe() is a DEVICE command, so it runs here against a stand-in
# dumpsys that prints a captured shape. Two shapes, because Android changed
# it. The probe was first written against an mResumedActivity line in each
# display's section (Android 16). Android 17 (SDK 37, measured on the
# reference device 2026-10-05) ends each section with "Resumed:
# ActivityRecord{...}" instead, and prints ONE global "ResumedActivity:" line
# after the last section, naming the top resumed activity across every
# display — often an app on an agent's virtual display, never safe to read
# as the person's.
mkdir -p "$T/fakebin"
cat > "$T/dump-37.txt" <<'EOF'
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
Display #5 (activities from top to bottom):
  * Task{333627a #348 type=standard A=10205:com.example.calculator U=0 visible=true visibleRequested=false mode=fullscreen translucent=false sz=1}
    mLastPausedActivity: ActivityRecord{259263821 u0 com.example.calculator/.Calculator t348}
    * Hist  #0: ActivityRecord{259263821 u0 com.example.calculator/.Calculator t348}
  * Task{cd1a8b #346 type=home U=0 visible=false visibleRequested=false mode=fullscreen translucent=true sz=1}
    * Hist  #0: ActivityRecord{146152427 u0 com.example.launcher/.SecondaryDisplayLauncher t346}
  Resumed activities in task display areas (from top to bottom):
    Resumed: ActivityRecord{259263821 u0 com.example.calculator/.Calculator t348}

Display #0 (activities from top to bottom):
  * Task{ee185c5 #1 type=home U=0 visible=true visibleRequested=false mode=fullscreen translucent=false sz=1}
    mLastPausedActivity: ActivityRecord{122922543 u0 com.example.launcher/.HomeActivity t2}
    * Hist  #0: ActivityRecord{122922543 u0 com.example.launcher/.HomeActivity t2}
  Resumed activities in task display areas (from top to bottom):
    Resumed: ActivityRecord{122922543 u0 com.example.launcher/.HomeActivity t2}

  ResumedActivity: ActivityRecord{259263821 u0 com.example.calculator/.Calculator t348}

ActivityTaskSupervisor state:
  mFocusedApp=ActivityRecord{259263821 u0 com.example.calculator/.Calculator t348}
EOF
cat > "$T/dump-36.txt" <<'EOF'
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
Display #5 (activities from top to bottom):
  * Task{1f2e3d #48 type=standard A=10205:com.example.calculator U=0 visible=true sz=1}
    mResumedActivity: ActivityRecord{1a2b3c u0 com.example.calculator/.Calculator t48}
    * Hist  #0: ActivityRecord{1a2b3c u0 com.example.calculator/.Calculator t48}

Display #0 (activities from top to bottom):
  * Task{4c5d6e #1 type=home U=0 visible=true sz=1}
    mResumedActivity: ActivityRecord{4d5e6f u0 com.example.launcher/.HomeActivity t1}
    * Hist  #0: ActivityRecord{4d5e6f u0 com.example.launcher/.HomeActivity t1}

  ResumedActivity: ActivityRecord{1a2b3c u0 com.example.calculator/.Calculator t48}
EOF
printf '#!/bin/sh\ncat "$FAKE_DUMP"\n' > "$T/fakebin/dumpsys"
chmod +x "$T/fakebin/dumpsys"
probe_on(){   # probe_on <display> <dump file>: what the probe says is in front
  py <<PY
$PRELUDE
import subprocess
m._DISPLAY[0] = $1
env = dict(os.environ, FAKE_DUMP="$2",
           PATH="$T/fakebin:" + os.environ.get("PATH", ""))
out = subprocess.run(["sh", "-c", m.resumed_probe()], capture_output=True,
                     text=True, env=env).stdout
print(m.foreground_of(out))
PY
}
for shape in 37 36; do
  a="$(probe_on 5 "$T/dump-$shape.txt")"
  [ "$a" = "com.example.calculator/.Calculator" ] \
    && ok "sdk $shape shape: a virtual display's front app is found" \
    || bad "sdk $shape shape, display 5: '$a'"
  b="$(probe_on 0 "$T/dump-$shape.txt")"
  [ "$b" = "com.example.launcher/.HomeActivity" ] \
    && ok "sdk $shape shape: display 0 is the person's app, not the global top" \
    || bad "sdk $shape shape, display 0: '$b'"
done
c="$(probe_on 7 "$T/dump-37.txt")"
[ "$c" = "(unknown)" ] \
  && ok "a display with no section reads as unknown, never as another's app" \
  || bad "display 7 (absent): '$c'"

# ------------------------------------------- an agent's display sleeps too
# While the phone dozes, an app on an agent's display is resumed and draws
# nothing (measured on the reference device, Android 17): no frame for the
# holder, no window for uiautomator. The failure must say that, not blame a
# display "nothing has been launched on" — and phone_awake() is a reason, not
# a gate: "could not tell" (None) must never become a refusal.
out="$(py <<PY
$PRELUDE
import io, contextlib
def shell_says(power):
    def fake(cmd, timeout=40, want_bytes=False):
        if "mWakefulness" in cmd:
            return (0, power) if power is not None else (1, "")
        if "uiautomator dump" in cmd:
            return (0, "__DUMP_OK__")
        return (0, "")
    return fake
for label, power in (("awake", "  mWakefulness=Awake"),
                     ("dozing", "  mWakefulness=Dozing"),
                     ("unknown", None)):
    m.dev_shell = shell_says(power)
    print(label, m.phone_awake())
def failure(fn):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        try:
            fn()
        except SystemExit as e:
            return e.code, err.getvalue()
    return None, err.getvalue()
m._display_name = lambda d: "pr-vd-1"
m.vd_client = lambda name, cmd, timeout=60: (
    1, "err java.lang.IllegalStateException: no frame rendered yet")
m.need_shell = lambda: None
m.dev_shell_checked = lambda cmd, timeout=90, attempts=4: (0, "")
for power in ("  mWakefulness=Dozing", "  mWakefulness=Awake"):
    m.dev_shell = shell_says(power)
    state = power.split("=")[1].lower()
    code, msg = failure(lambda: m._vd_capture(5))
    print("cap", state, code, "asleep" if "asleep" in msg else "plain")
    code, msg = failure(lambda: m.get_ui(None, display=5))
    print("ui5", state, code, "asleep" if "asleep" in msg else "plain")
m.dev_shell = shell_says("  mWakefulness=Dozing")
code, msg = failure(lambda: m.get_ui(None, display=0))
print("ui0 dozing", code, "asleep" if "asleep" in msg else "plain")
PY
)"
for want in "awake True" "dozing False" "unknown None"; do
  echo "$out" | grep -qx "$want" && ok "phone_awake: $want" || bad "phone_awake ($want): $out"
done
echo "$out" | grep -qx "cap dozing 4 asleep" \
  && ok "no frame on a dozing phone says the phone is asleep" || bad "cap dozing: $out"
echo "$out" | grep -qx "cap awake 4 plain" \
  && ok "no frame on an awake phone keeps the old reason" || bad "cap awake: $out"
echo "$out" | grep -qx "ui5 dozing 4 asleep" \
  && ok "no tree on an agent's display says the phone is asleep" || bad "ui5 dozing: $out"
echo "$out" | grep -qx "ui5 awake 4 plain" \
  && ok "no tree on an awake phone keeps the old reason" || bad "ui5 awake: $out"
echo "$out" | grep -qx "ui0 dozing 4 plain" \
  && ok "display 0 keeps its own message" || bad "ui0: $out"

# ------------------------------------------------------- the holder's names
# The holder is found by NAME — there is no registry file — so the prefix it
# is started under and the prefix `displays()` claims as ours must be one and
# the same, and the jar and classes must be the ones the build installs.
cat > "$T/get-displays.txt" <<'EOF'
Displays:
Display id 0: DisplayInfo{"Built-in Screen", displayId 0, type INTERNAL, real 1080 x 2424, density 420, flags FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_TRUSTED}
Display id 6: DisplayInfo{"pr-vd-1", displayId 6, type VIRTUAL, real 1080 x 2424, density 420, flags FLAG_TRUSTED}
Display id 7: DisplayInfo{"Overlay #1", displayId 7, type OVERLAY, real 720 x 1280, density 320, flags FLAG_TRUSTED}
EOF
out="$(py <<PY
$PRELUDE
fixture = open("$T/get-displays.txt").read()
ran = []
def fake(cmd, timeout=40, want_bytes=False):
    ran.append(cmd)
    if cmd.startswith("ls "):
        return 0, "/data/local/tmp/parallel-root-vdisplay.jar\n"
    if cmd == "cmd display get-displays":
        return 0, fixture
    if "vdisplay.Client" in cmd:
        return 0, "9 1080x2424/420\n"
    if "app_process" in cmd:
        return 0, "display 9\n"
    return 0, ""
m.dev_shell = fake
m.have_shell = lambda: True
ours = {d["id"]: d["ours"] for d in m.displays()}
print("ours=%s" % ",".join(str(i) for i in sorted(k for k, v in ours.items() if v)))
args = m.build_parser().parse_args(["display", "create"])
m.cmd_display(args)
launch = [c for c in ran if "app_process" in c][0]
print("jar" if "CLASSPATH=/data/local/tmp/parallel-root-vdisplay.jar" in launch else "nojar")
print("main" if " parallelroot.vdisplay.Main " in launch else "nomain")
print("name" if "--name pr-vd-2 --socket pr-vd-2" in launch else "noname:" + launch)
import re
print("ownlog" if re.search(r"> /data/local/tmp/pr-vd-2-%d-[0-9]+\.log " % os.getpid(), launch)
      else "sharedlog:" + launch)
asked = [c for c in ran if "vdisplay.Client pr-vd-2 info" in c]
print("confirmed" if asked else "unconfirmed")
ran.clear()
m.vd_client("pr-vd-1", "bye")
print("client" if ran and "parallelroot.vdisplay.Client pr-vd-1 bye" in ran[0] else "noclient")
PY
)"
[ "$(echo "$out" | sed -n 1p)" = "ours=6" ] \
  && ok "only a pr-vd- display counts as ours" || bad "holder detection: $out"
echo "$out" | grep -qx "jar" && ok "the holder runs from /data/local/tmp/parallel-root-vdisplay.jar" \
  || bad "holder jar: $out"
echo "$out" | grep -qx "main" && ok "as parallelroot.vdisplay.Main" || bad "holder class: $out"
echo "$out" | grep -qx "name" && ok "named after the next free pr-vd- slot" || bad "holder name: $out"
echo "$out" | grep -qx "ownlog" && ok "each create writes a log of its own, not one per name" \
  || bad "holder log: $out"
echo "$out" | grep -qx "confirmed" && ok "and the id is confirmed with the holder that answers to that name" \
  || bad "holder id not confirmed: $out"
echo "$out" | grep -qx "client" && ok "and is asked things through parallelroot.vdisplay.Client" \
  || bad "holder client: $out"

# Two creates that overlap can choose the same free name. The holder claims
# its name before it makes a display, so the one that loses prints the bind's
# EADDRINUSE and nothing else; an older holder that made its display first
# prints an id whose name another holder answers to. Either is a clash, and
# the next free name is tried. A holder that answers to nobody is not a clash
# to retry past: that display's id is reported, never a fresh one on top.
cat > "$T/clash.py" <<PY
$PRELUDE
import contextlib, io, re
fixture = open("$T/get-displays.txt").read()
mode = sys.argv[1]
launched, held_by = [], {}
def fake(cmd, timeout=40, want_bytes=False):
    if cmd.startswith("ls "):
        return 0, "/data/local/tmp/parallel-root-vdisplay.jar\n"
    if cmd == "cmd display get-displays":
        return 0, fixture
    if "vdisplay.Client" in cmd:
        name = cmd.split("vdisplay.Client ", 1)[1].split()[0]
        if mode == "silent":
            return 1, "err java.io.IOException: Connection refused\n"
        return 0, "%d 1080x2424/420\n" % held_by[name]
    if "vdisplay.Main" in cmd:
        name = re.search(r"--name (\S+)", cmd).group(1)
        launched.append((name, re.search(r"> (\S+\.log) ", cmd).group(1)))
        if mode == "bind" and name == "pr-vd-2":
            return 0, "vdisplay: java.io.IOException: bind failed: EADDRINUSE (Address already in use)\n"
        if mode == "late" and name == "pr-vd-2":
            held_by[name] = 12            # another create's holder won it
            return 0, "display 10\n"
        if mode == "always":
            return 0, "vdisplay: java.io.IOException: Address already in use\n"
        held_by[name] = 11
        return 0, "display 11\n"
    return 0, ""
m.dev_shell = fake
m.have_shell = lambda: True
out, code = io.StringIO(), 0
try:
    with contextlib.redirect_stdout(out):
        m.cmd_display(m.build_parser().parse_args(["display", "create"]))
except SystemExit as e:
    code = e.code
logs = [l for _n, l in launched]
print("code=%s printed=%s tried=%s distinct_logs=%s" % (
    code, out.getvalue().strip() or "-", ",".join(n for n, _l in launched),
    len(set(logs)) == len(logs)))
PY
out="$(py "bind" < "$T/clash.py" 2>&1)"
[ "$out" = "code=0 printed=11 tried=pr-vd-2,pr-vd-3 distinct_logs=True" ] \
  && ok "a name another holder took first is passed over for the next free one" \
  || bad "bind clash: $out"
out="$(py "late" < "$T/clash.py" 2>&1)"
[ "$out" = "code=0 printed=11 tried=pr-vd-2,pr-vd-3 distinct_logs=True" ] \
  && ok "so is an id whose name answers for someone else's display" \
  || bad "late clash: $out"
out="$(py "silent" < "$T/clash.py" 2>&1)"
case "$out" in
  *"display 11 came up, but no holder answers to pr-vd-2"*"code=4 printed=- tried=pr-vd-2 "*)
    ok "a holder that answers to nobody is reported by its id, not retried" ;;
  *) bad "unanswered holder: $out" ;;
esac
out="$(py "always" < "$T/clash.py" 2>&1)"
case "$out" in
  *"no free holder name after 5 tries"*"code=4 printed=- tried=pr-vd-2,pr-vd-3,pr-vd-4,pr-vd-5,pr-vd-6 "*)
    ok "and the retries are bounded" ;;
  *) bad "endless clash: $out" ;;
esac
out="$(py 2>&1 <<PY
$PRELUDE
m.dev_shell = lambda cmd, timeout=40, want_bytes=False: (1, "")
m.have_shell = lambda: True
try:
    m.cmd_display(m.build_parser().parse_args(["display", "create"]))
    print("created without a jar")
except SystemExit as e:
    print("exit %s" % e.code)
PY
)"
if echo "$out" | grep -q "android/vdisplay/build.sh install" && echo "$out" | grep -q "exit 3"; then
  ok "with no jar staged, create says how to build and stage one"
else bad "missing holder message: $out"; fi

# ------------------------------------------------------ lease per display
export PHONE_SHELL_SOCK="$T/shell.sock"
export PHONE_SHELL_ARGV=sh
"$PHONE" shelld --start >/dev/null 2>&1
if [ -S "$T/shell.sock" ]; then
  "$PHONE" --display 3 lease acquire --as driverA >/dev/null 2>&1
  "$PHONE" --display 4 lease acquire --as driverB >/dev/null 2>&1
  a="$("$PHONE" --display 3 lease status 2>&1 | awk '{print $1}')"
  b="$("$PHONE" --display 4 lease status 2>&1 | awk '{print $1}')"
  [ "$a" = "driverA" ] && [ "$b" = "driverB" ] \
    && ok "two displays, two holders, at the same time" \
    || bad "holders were '$a' and '$b'"

  "$PHONE" --display 3 lease acquire --as driverB >/dev/null 2>&1
  [ $? -eq 5 ] && ok "a held display refuses a second driver" \
    || bad "driverB took a display driverA holds"

  # The gate in main() is what actually stops a verb.
  PHONE_ACTOR=driverC "$PHONE" --display 3 tap 5 5 >/dev/null 2>&1
  [ $? -eq 5 ] && ok "a mutating verb is refused on someone else's display" \
    || bad "tap was not gated on display 3"

  # The built-in screen is a display like any other, and must not have been
  # taken by either of the above.
  z="$("$PHONE" lease status 2>&1)"
  [ "$z" = "free" ] && ok "holding a virtual display leaves display 0 free" \
    || bad "display 0 says: $z"

  # A holder is ONE word. The protocol is a line split on spaces: "agent b"
  # went out as `acquire agent b 300 5`, the daemon read "b" as the TTL, and
  # the ValueError ended it, taking driverA's lease on display 3 with it.
  out="$("$PHONE" --display 5 lease acquire --as "agent b" 2>&1)"; rc=$?
  if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q "one word"; then
    ok "a holder name with a space is refused (exit 2) before anything is sent"
  else bad "holder with a space (rc=$rc out=$out)"; fi
  PHONE_ACTOR="agent b" "$PHONE" --display 5 lease acquire >/dev/null 2>&1
  [ $? -eq 2 ] && ok "and so is a PHONE_ACTOR with a space in it" \
    || bad "PHONE_ACTOR with a space was sent as a holder"
  "$PHONE" --display 3 lease release --as "driverA 3" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "a release under such a name is refused too, not reported done" \
    || bad "release with a two-word holder was not refused"
  # And the daemon itself must survive a request it cannot read, from
  # whatever else speaks the protocol: answered as a refused request (2),
  # while the leases it holds stay held.
  out="$(py <<'PY'
import os, socket
def ask(line):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(os.environ["PHONE_SHELL_SOCK"])
    s.sendall(("\0lease " + line + "\n").encode())
    buf = b""
    while b"__PHONE_EOC__" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return buf.decode().strip()
for line in ("acquire agent b 300 5", "acquire carol inf 5", "acquire carol nan 5"):
    print(ask(line))
PY
)"
  if [ "$(printf '%s\n' "$out" | grep -c '^bad lease request__PHONE_EOC__ 2$')" = "3" ]; then
    ok "the daemon answers a request it cannot read as refused (2)"
  else bad "daemon replies to bad requests: $out"; fi
  a="$("$PHONE" --display 3 lease status 2>&1 | awk '{print $1}')"
  z="$("$PHONE" --display 5 lease status 2>&1)"
  [ "$a" = "driverA" ] && [ "$z" = "free" ] \
    && ok "and the lease held on display 3 survives all of it" \
    || bad "after bad requests: display 3 '$a', display 5 '$z'"

  # display rm and display move act on displays they NAME, which the gate in
  # main() never sees. They ask the lease of each display they touch. Run as
  # module calls against this daemon, with the phone's side stubbed: three
  # holders (3 and 4 held by driverA and driverB, 5 free) and two overlays,
  # 7, which driverB holds too, and 8. Overlays are entries in one setting
  # that Android re-creates whole on any change, so removing 8 touches 7.
  "$PHONE" --display 7 lease acquire --as driverB >/dev/null 2>&1
  cat > "$T/held-displays.txt" <<'EOF'
Displays:
Display id 0: DisplayInfo{"Built-in Screen", displayId 0, type INTERNAL, real 1080 x 2424, density 420, flags FLAG_TRUSTED}
Display id 3: DisplayInfo{"pr-vd-1", displayId 3, type VIRTUAL, real 1080 x 2424, density 420, flags FLAG_TRUSTED}
Display id 4: DisplayInfo{"pr-vd-2", displayId 4, type VIRTUAL, real 1080 x 2424, density 420, flags FLAG_TRUSTED}
Display id 5: DisplayInfo{"pr-vd-3", displayId 5, type VIRTUAL, real 1080 x 2424, density 420, flags FLAG_TRUSTED}
Display id 7: DisplayInfo{"Overlay #1", displayId 7, type OVERLAY, real 720 x 1280, density 320, flags FLAG_TRUSTED}
Display id 8: DisplayInfo{"Overlay #2", displayId 8, type OVERLAY, real 720 x 1280, density 320, flags FLAG_TRUSTED}
EOF
  cat > "$T/held.py" <<PY
$PRELUDE
import contextlib, io
fixture = open("$T/held-displays.txt").read()
sent = []
def fake(cmd, timeout=40, want_bytes=False):
    if cmd == "cmd display get-displays":
        return 0, fixture
    if cmd.startswith("dumpsys activity activities"):
        return 0, ("Display #4 (activities from top to bottom):\n"
                   "  * ActivityRecord{a1 u0 com.example.notes/.Main t9}\n"
                   "Display #5 (activities from top to bottom):\n"
                   "  * ActivityRecord{b2 u0 com.example.clock/.Main t8}\n")
    if cmd.startswith("pm list packages"):
        return 0, "package:com.example.notes\npackage:com.example.clock\n"
    if "resolve-activity" in cmd:
        return 0, cmd.split()[-3] + "/.Main\n"
    if cmd.startswith("settings get global overlay_display_devices"):
        return 0, "720x1280/320;720x1280/320\n"
    if cmd.startswith(("settings put", "am start")):
        sent.append(cmd)
    return 0, ""
m.dev_shell = fake
m.have_shell = lambda: True
m.time.sleep = lambda s: None
m.vd_client = lambda sock, cmd, timeout=60: (sent.append("%s %s" % (sock, cmd)), (0, "ok"))[1]
def run(actor, *argv):
    os.environ["PHONE_ACTOR"] = actor
    del sent[:]
    out, code = io.StringIO(), 0
    try:
        with contextlib.redirect_stdout(out):
            m.cmd_display(m.build_parser().parse_args(["display"] + list(argv)))
    except SystemExit as e:
        code = e.code
    return code, out.getvalue(), list(sent)
code, _o, sent_ = run("driverC", "rm", "3")
print("rm-held", code, "bye" if sent_ else "nothing-sent")
code, _o, sent_ = run("driverC", "rm", "7")
print("rm-overlay-held", code, "written" if sent_ else "nothing-sent")
code, _o, sent_ = run("driverC", "rm", "8")
print("rm-overlay-beside-held", code, "written" if sent_ else "nothing-sent")
code, _o, sent_ = run("driverC", "create", "--visible")
print("visible-beside-held", code, "written" if sent_ else "nothing-sent")
code, o, sent_ = run("driverC", "rm", "--all")
print("all", code, " ".join(sorted(sent_)) or "-")
print("all-names", "driverA" in o and "driverB" in o and "left every overlay" in o)
code, _o, sent_ = run("driverC", "move", "notes", "--to", "5")
print("move-off-held", code, "moved" if sent_ else "nothing-sent")
code, _o, sent_ = run("driverC", "move", "clock", "--to", "3")
print("move-onto-held", code, "moved" if sent_ else "nothing-sent")
code, _o, sent_ = run("driverA", "rm", "3")
print("rm-own", code, " ".join(sent_) or "-")
PY
  out="$(py < "$T/held.py" 2>/dev/null)"
  printf '%s\n' "$out" | grep -qx "rm-held 5 nothing-sent" \
    && ok "display rm refuses a display another driver holds (exit 5)" \
    || bad "display rm of a held display: $out"
  printf '%s\n' "$out" | grep -qx "rm-overlay-held 5 nothing-sent" \
    && ok "an overlay display is held like any other" \
    || bad "display rm of a held overlay: $out"
  printf '%s\n' "$out" | grep -qx "rm-overlay-beside-held 5 nothing-sent" \
    && ok "and removing another overlay, which re-creates the held one, is refused" \
    || bad "display rm of an overlay beside a held one: $out"
  printf '%s\n' "$out" | grep -qx "visible-beside-held 5 nothing-sent" \
    && ok "as is adding a visible display, for the same reason" \
    || bad "display create --visible beside a held overlay: $out"
  printf '%s\n' "$out" | grep -qx "all 0 pr-vd-3 bye" \
    && ok "rm --all releases only the displays nobody else holds" \
    || bad "display rm --all under leases: $out"
  printf '%s\n' "$out" | grep -qx "all-names True" \
    && ok "and names the holders of what it left, overlays included" \
    || bad "display rm --all did not say what it left: $out"
  printf '%s\n' "$out" | grep -qx "move-off-held 5 nothing-sent" \
    && ok "display move will not take an app off a held display" \
    || bad "display move off a held display: $out"
  printf '%s\n' "$out" | grep -qx "move-onto-held 5 nothing-sent" \
    && ok "nor put one onto a held display" \
    || bad "display move onto a held display: $out"
  printf '%s\n' "$out" | grep -qx "rm-own 0 pr-vd-1 bye" \
    && ok "while the holder may release its own" \
    || bad "display rm by the holder: $out"
  "$PHONE" --display 7 lease release --as driverB >/dev/null 2>&1

  "$PHONE" --display 3 lease release --as driverA >/dev/null 2>&1
  z="$("$PHONE" --display 3 lease status 2>&1)"
  [ "$z" = "free" ] && ok "release frees only that display" || bad "after release: $z"
  b="$("$PHONE" --display 4 lease status 2>&1 | awk '{print $1}')"
  [ "$b" = "driverB" ] && ok "the other display's lease survives" || bad "display 4: $b"
else
  echo "skip lease tests (no local daemon)"
fi
"$PHONE" shelld --stop >/dev/null 2>&1

# ------------------------------------------------- move / visible surface
h="$("$PHONE" display --help 2>&1)"
echo "$h" | grep -q -- "--visible" && ok "create has a --visible mode" \
  || bad "no --visible in display --help"
echo "$h" | grep -q "move" && ok "display can move an app between screens" \
  || bad "no move action"
# `;` separates overlay displays and `,` separates one display's flags — a
# parser that gets this backwards silently merges two screens into one.
out="$(py <<PY
$PRELUDE
m.dev_shell = lambda *a, **k: (0, "1080x2400/420;800x600/240")
print("|".join(m.overlay_specs()))
m.dev_shell = lambda *a, **k: (0, "null")
print("empty" if m.overlay_specs() == [] else "not-empty")
PY
)"
[ "$(echo "$out" | sed -n 1p)" = "1080x2400/420|800x600/240" ] \
  && ok "overlay specs split on ; not ," || bad "overlay parse: $out"
[ "$(echo "$out" | sed -n 2p)" = "empty" ] \
  && ok "an unset overlay setting reads as none" || bad "null parse: $out"

# ------------------------------------------------------------- the lanes
# A lane is a driver's own shelld. The default lane must stay exactly where
# it was, or every existing caller moves house.
out="$(py <<PY
$PRELUDE
os.environ.pop("PHONE_SHELL_SOCK", None)
os.environ["PREFIX"] = "/tmp"
os.environ.pop("PHONE_LANE", None)
print(m.shell_sock())
os.environ["PHONE_LANE"] = "alpha"
print(m.shell_sock())
print(m._laned("/a/b/phone-shell.sock"))
PY
)"
[ "$(echo "$out" | sed -n 1p)" = "/tmp/tmp/phone-shell.sock" ]   && ok "the default lane's socket is unchanged" || bad "default sock: $out"
[ "$(echo "$out" | sed -n 2p)" = "/tmp/tmp/phone-shell-alpha.sock" ]   && ok "a lane gets its own socket" || bad "lane sock: $out"
[ "$(echo "$out" | sed -n 3p)" = "/a/b/phone-shell-alpha.sock" ]   && ok "the remote socket is laned the same way" || bad "laned: $out"

out="$(py <<PY
$PRELUDE
os.environ["PHONE_LANE"] = "no spaces please"
try:
    m.lane()
    print("accepted")
except SystemExit:
    print("refused")
PY
)"
[ "$out" = "refused" ] && ok "a malformed lane name is refused" || bad "lane validation: $out"

# Two local daemons, two lanes, at once.
export PHONE_SHELL_ARGV=sh
unset PHONE_SHELL_SOCK
export PREFIX="$T"
mkdir -p "$T/tmp"
PHONE_LANE=alpha "$PHONE" shelld --start >/dev/null 2>&1
PHONE_LANE=beta  "$PHONE" shelld --start >/dev/null 2>&1
if [ -S "$T/tmp/phone-shell-alpha.sock" ] && [ -S "$T/tmp/phone-shell-beta.sock" ]; then
  ok "two lanes stand up two daemons"
  # Each lane's lease is its own, which is the trade lanes make: a driver
  # that takes a lane has taken itself out of the shared arbiter.
  PHONE_LANE=alpha "$PHONE" --display 3 lease acquire --as driverA >/dev/null 2>&1
  z="$(PHONE_LANE=beta "$PHONE" --display 3 lease status 2>&1)"
  [ "$z" = "free" ] && ok "a lane does not see another lane's lease"     || bad "lane beta saw: $z"
  z="$(PHONE_LANE=alpha "$PHONE" --display 3 lease status 2>&1 | awk '{print $1}')"
  [ "$z" = "driverA" ] && ok "and still holds its own" || bad "lane alpha: $z"
else
  bad "two lanes did not produce two sockets"
fi
PHONE_LANE=alpha "$PHONE" shelld --stop >/dev/null 2>&1
PHONE_LANE=beta  "$PHONE" shelld --stop >/dev/null 2>&1
export PREFIX="$T/prefix"
unset PHONE_SHELL_ARGV

# ------------------------------------------------------------ the device
if [ -z "$DEV" ]; then
  echo "skip device tests (set PHONE_TEST_DEVICE=<ssh-host> to run them)"
else
  # The caller's PATH and PREFIX back, for a real ssh. PHONE_LANE and
  # PHONE_REMOTE_BIN were never touched: they are the caller's to set.
  export PATH="$ORIG_PATH"
  if [ -n "$ORIG_PREFIX" ]; then export PREFIX="$ORIG_PREFIX"; else unset PREFIX; fi
  unset PHONE_SHELL_SOCK PHONE_SHELL_ARGV
  INTRUSIVE="${PHONE_TEST_INTRUSIVE:-}"
  dphone(){ "$PHONE" --device "$DEV" "$@"; }

  ids=" $(dphone display ls 2>&1 | awk '{print $1}' | tr '\n' ' ') "
  case "$ids" in
    *" 0 "*) ok "display ls finds the built-in screen" ;;
    *) bad "display ls: $ids" ;;
  esac

  fg_before="$(dphone foreground 2>&1)"
  d="$(dphone display create 2>&1 | tail -1)"
  case "$d" in
    ''|*[!0-9]*) bad "display create returned '$d'" ;;
    *)
      CREATED="$CREATED $d"
      ok "display create -> id $d"
      # Pick an app that is not already somewhere. The suite used to hardcode
      # the clock and then fail whenever a previous run had left one open —
      # reporting the one-app-one-display guard, working exactly as designed,
      # as a broken launch.
      app=""
      for cand in clock calculator contacts photos; do
        if dphone --display "$d" open "$cand" >/dev/null 2>&1
        then app="$cand"; break; fi
      done
      if [ -z "$app" ]; then
        bad "no candidate app was free to launch on display $d"
      else
        fg="$(dphone --display "$d" foreground 2>&1)"
        case "$fg" in
          *SecondaryDisplayLauncher*|*nexuslauncher*)
            bad "display $d still shows its launcher: $fg" ;;
          *) ok "$app launches onto display $d" ;;
        esac

        fg_after="$(dphone foreground 2>&1)"
        [ "$fg_after" = "$fg_before" ] \
          && ok "the built-in screen was not disturbed" \
          || bad "display 0 changed: '$fg_before' -> '$fg_after'"

        # The guard is tried from a SECOND virtual display, not from display
        # 0. Asked on display 0, a guard that had regressed would put the app
        # on the screen in the person's hand.
        d2="$(dphone display create 2>&1 | tail -1)"
        case "$d2" in
          ''|*[!0-9]*) bad "a second display for the guard test returned '$d2'" ;;
          *)
            CREATED="$CREATED $d2"
            dphone --display "$d2" open "$app" >/dev/null 2>&1
            [ $? -eq 5 ] && ok "the same app is refused a second display" \
              || bad "one-app-one-display was not enforced"
            release "$d2" || bad "could not release display $d2"
            ;;
        esac

        # An agent's display sleeps when the phone does: the app above is
        # resumed, and draws nothing until the phone wakes. Waking it lights
        # the person's screen, so only the intrusive run does that; otherwise
        # a sleeping phone is checked for the honest message instead.
        power="$(dphone sh "dumpsys power | grep -m1 mWakefulness=" 2>/dev/null)"
        case "$power" in *Awake*) awake=1 ;; *) awake="" ;; esac
        if [ -z "$awake" ] && [ "$INTRUSIVE" = "1" ]; then
          dphone sh "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1
          sleep 1.5
          awake=1
        fi
        if [ -n "$awake" ]; then
          dphone --display "$d" look >/dev/null 2>&1 \
            && ok "look reads display $d" || bad "look failed on display $d"

          dphone --display "$d" screen --out "$T/d.png" >/dev/null 2>&1
          # The magic bytes, not `grep -q PNG`: BSD grep exits 1 on binary
          # input even when the pattern is there, so that check reported
          # every good screenshot as a failure.
          magic="$(head -c 4 "$T/d.png" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
          [ "$magic" = "89504e47" ] \
            && ok "screen captures display $d ($(wc -c < "$T/d.png" | tr -d ' ') bytes)" \
            || bad "display $d produced no PNG (magic '$magic')"
        else
          err="$(dphone --display "$d" look 2>&1)"
          case "$err" in
            *asleep*) ok "on a sleeping phone, look on display $d says the phone is asleep" ;;
            *) bad "look on a sleeping phone said: ${err:0:90}" ;;
          esac
          err="$(dphone --display "$d" screen --out "$T/d.png" 2>&1)"
          case "$err" in
            *asleep*) ok "and so does screen" ;;
            *) bad "screen on a sleeping phone said: ${err:0:90}" ;;
          esac
          echo "skip reading pixels on display $d (the phone is asleep and agent displays sleep with it; set PHONE_TEST_INTRUSIVE=1 to wake it)"
        fi

        # move is the sanctioned way past the one-app-one-display guard — and
        # moving to 0 puts the app in front of the person, so it is opt-in.
        if [ "$INTRUSIVE" = "1" ]; then
          dphone display move "$app" --to 0 >/dev/null 2>&1 \
            && ok "display move brings an app to the built-in screen" \
            || bad "display move to 0 failed"
          dphone display move "$app" --to "$d" >/dev/null 2>&1 \
            && ok "and moves it back off again" || bad "display move back failed"
        else
          echo "skip display move --to 0 (it puts $app on the person's screen; set PHONE_TEST_INTRUSIVE=1)"
        fi
      fi
      release "$d" && ok "display rm releases it" || bad "display rm failed"
      ;;
  esac

  # A visible display is a window floating over the person's own screen.
  if [ "$INTRUSIVE" = "1" ]; then
    v="$(dphone display create --visible 2>&1 | tail -1)"
    case "$v" in
      ''|*[!0-9]*) bad "display create --visible returned '$v'" ;;
      *) CREATED="$CREATED $v"
         ok "a visible display appears (id $v)"
         dphone --display "$v" look >/dev/null 2>&1 \
           && ok "a visible display can still be read" \
           || bad "look failed on visible display $v"
         # It has no framebuffer of its own, and saying so is better than
         # handing back the built-in screen and calling it that display.
         err="$(dphone --display "$v" screen --out "$T/v.png" 2>&1)"
         case "$err" in
           *"no framebuffer"*) ok "and says why it cannot be screenshotted" ;;
           *) bad "visible-display screen said: ${err:0:70}" ;;
         esac
         release "$v" && ok "a visible display is released too" \
           || bad "rm visible failed"
         ;;
    esac
  else
    echo "skip display create --visible (it floats a window over the person's screen; set PHONE_TEST_INTRUSIVE=1)"
  fi
  # Anything still in CREATED is released by id on the way out (cleanup).
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
