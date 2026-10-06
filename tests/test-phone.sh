#!/usr/bin/env bash
# The `phone` verb layer: one CLI that turns an Android phone (Termux +
# Shizuku, no root) into a surface any agent can drive. The testable core is
# the PARSING — the UI tree and the notification inbox — because that is what
# an LLM actually reasons over. Device I/O is shelled out and stubbed here,
# and nothing in this suite reaches a real phone.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHONE="$HERE/bin/phone"
# /tmp rather than $TMPDIR, deliberately: the daemons below listen on unix
# sockets inside this directory, and a long TMPDIR (macOS gives one) pushes a
# socket path past the 104-byte limit, which fails as a bind error.
T="$(mktemp -d /tmp/phone-test.XXXXXX)"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$*"; }
bad(){ fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT

# Hermetic. Nothing from the caller's PHONE_* environment reaches the CLI: an
# exported PHONE_DEVICE alone would have a dozen verbs below stand up an ssh
# forward to a real phone, and a PHONE_NO_LEASE would quietly pass every lease
# test. The tests that need a setting pass it themselves.
for v in $(compgen -e); do
  case "$v" in PHONE_*) unset "$v" ;; esac
done
# The caller's config file is theirs too. Point at one that cannot exist; the
# config tests below write their own.
export PHONE_CONFIG="$T/no-such-config"
# The ledger is the accountability record, so the suite must never write to
# the real one. It did: every lease and shell-verb test that did not set
# PHONE_LEDGER itself appended to the real ledger, leaving 138 rows with
# actors named "intruder", "ghost" and "driver1" in the file a human is
# supposed to consult to find out who touched their phone.
# Exported once here so it is the default for every invocation; the tests that
# set it explicitly still override it.
export PHONE_LEDGER="$T/default-ledger.jsonl"
# And no real device tier, whatever this machine has: a rish that does not
# exist, a default daemon socket nobody listens on, and an ssh and an adb that
# fail at once. Tests that need a device put their own stubs IN FRONT of these.
export PHONE_RISH="$T/no-rish"
export PREFIX="$T/prefix"
# Several tests import bin/phone as a module; none of them may leave a
# bytecode cache behind in the checkout.
export PYTHONDONTWRITEBYTECODE=1
NODEV="$T/nodev"; mkdir -p "$NODEV"
cat > "$NODEV/ssh" <<'EOF'
#!/bin/sh
echo "ssh: this test suite never reaches a real host" >&2
exit 255
EOF
cat > "$NODEV/adb" <<'EOF'
#!/bin/sh
# No device is ever attached.
[ "$1" = devices ] && { printf 'List of devices attached\n\n'; exit 0; }
exit 1
EOF
chmod +x "$NODEV/ssh" "$NODEV/adb"
export PATH="$NODEV:$PATH"

# Load `phone` as a module, for the tests that check a function directly. It
# has no .py suffix and is meant to stay one file, so the import is by path.
PRELUDE='
import importlib.util, importlib.machinery, os, sys
spec = importlib.util.spec_from_loader(
    "phonemod", importlib.machinery.SourceFileLoader(
        "phonemod", os.environ["PHONE_PATH"]))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
'

# A realistic uiautomator dump: nested nodes, the label NOT itself clickable
# (the real messaging/mail-app shape — text sits inside a clickable row).
cat > "$T/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8'?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.whatsapp" content-desc="" clickable="false" enabled="true" bounds="[0,0][1080,2424]">
    <node index="1" text="" resource-id="com.whatsapp:id/conversation" class="android.view.ViewGroup" package="com.whatsapp" content-desc="" clickable="true" enabled="true" bounds="[0,300][1080,500]">
      <node index="0" text="Alice Moreau" resource-id="com.whatsapp:id/conversation_contact_name" class="android.widget.TextView" package="com.whatsapp" content-desc="" clickable="false" enabled="true" bounds="[100,320][600,380]" />
      <node index="1" text="the train is delayed" resource-id="com.whatsapp:id/single_msg" class="android.widget.TextView" package="com.whatsapp" content-desc="" clickable="false" enabled="true" bounds="[100,400][700,460]" />
    </node>
    <node index="2" text="" resource-id="com.whatsapp:id/send" class="android.widget.ImageButton" package="com.whatsapp" content-desc="Send" clickable="true" enabled="true" bounds="[900,2000][1000,2100]" />
    <node index="3" text="Disabled thing" resource-id="" class="android.widget.Button" package="com.whatsapp" content-desc="" clickable="true" enabled="false" bounds="[0,1000][200,1100]" />
  </node>
</hierarchy>
XML

# Every name, message and account below is invented: a chat message, a bank's
# email, a system notification, and a group chat whose text is all in `lines`.
cat > "$T/notifs.json" <<'JSON'
[
  {"id":1,"tag":"","key":"0|com.whatsapp|1|null|10123","group":"","packageName":"com.whatsapp","title":"Alice Moreau","content":"the train is delayed","when":"2026-08-23 09:15:00"},
  {"id":2,"tag":"","key":"0|com.google.android.gm|2|null|10200","group":"","packageName":"com.google.android.gm","title":"Example Bank","content":"Your statement is ready","when":"2026-08-23 08:00:00"},
  {"id":3,"tag":"","key":"0|com.example.system|3|null|10300","group":"","packageName":"com.example.system","title":"Storage almost full","content":"Free up space to keep apps running","when":"2026-08-22 23:00:00"},
  {"id":4,"tag":"","key":"0|com.whatsapp|4|null|10123","group":"","packageName":"com.whatsapp","title":"Bob Tanaka","content":"can you send the photos?","when":"2026-08-23 10:02:00"},
  {"id":5,"tag":"","key":"0|com.whatsapp|5|null|10123","group":"","packageName":"com.whatsapp","title":"Hiking club","content":"","lines":["Carol: moved the start to 9","Erin: works for me"],"when":"2026-08-23 10:05:00"}
]
JSON

echo "== the CLI exists and is honest about unknown verbs"
if [ -x "$PHONE" ]; then ok "bin/phone is executable"; else bad "bin/phone missing or not executable"; fi
out="$("$PHONE" definitely-not-a-verb 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "unknown verb"; then
  ok "unknown verb -> non-zero exit + honest message"
else bad "unknown verb handling (rc=$rc out=$out)"; fi

echo "== an unknown verb is refused before any hop"
# A verb this CLI does not have is a usage error whether or not the phone is
# reachable; finding that out must not cost an ssh round trip, or come back
# as "no device" because the phone is away.
out="$("$PHONE" --device test-phone definitely-not-a-verb 2>&1)"; rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q "unknown verb"; then
  ok "with --device, an unknown verb is refused before any ssh is attempted"
else bad "unknown verb with --device (rc=$rc out=$out)"; fi

echo "== ui: parse a real uiautomator tree into LLM-readable lines"
out="$("$PHONE" ui --from "$T/ui.xml" 2>&1)"
if printf '%s' "$out" | grep -q "Alice Moreau" && printf '%s' "$out" | grep -q "Send"; then
  ok "ui lists on-screen text and content-desc"
else bad "ui parse (got: $out)"; fi
if printf '%s' "$out" | grep -qE "\[?[0-9]+,[0-9]+\]?"; then
  ok "ui emits tappable coordinates"
else bad "ui coordinates missing"; fi

echo "== find: text -> the CLICKABLE ancestor's center (the real-app shape)"
# "Alice Moreau" is a non-clickable TextView inside a clickable row
# [0,300][1080,500] -> center 540,400. Tapping the label's own center (350,350)
# would miss the row's handler in many apps.
out="$("$PHONE" find "Alice Moreau" --from "$T/ui.xml" 2>&1)"
if printf '%s' "$out" | grep -q "540" && printf '%s' "$out" | grep -q "400"; then
  ok "find resolves a label to its clickable ancestor's center"
else bad "find clickable-ancestor (got: $out)"; fi

echo "== find: content-desc matches too (icon buttons have no text)"
out="$("$PHONE" find "Send" --from "$T/ui.xml" 2>&1)"
if printf '%s' "$out" | grep -q "950" && printf '%s' "$out" | grep -q "2050"; then
  ok "find matches content-desc (Send button center)"
else bad "find content-desc (got: $out)"; fi

echo "== find: case-insensitive, and misses are honest (not a wrong tap)"
out="$("$PHONE" find "alice moreau" --from "$T/ui.xml" 2>&1)"
if printf '%s' "$out" | grep -q "540"; then ok "find is case-insensitive"
else bad "find case-insensitivity (got: $out)"; fi

# The two shapes that made a tap buy something, reproduced from overlay
# geometry measured on a reference device (ids and labels invented): an item
# row whose centre lies inside a floating cart bar, and an option row whose
# centre lies inside the add button. In both the overlay comes LATER in the
# tree, which is what makes it the thing a finger actually hits.
cat > "$T/store.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8'?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.shop" clickable="false" enabled="true" bounds="[0,0][1080,2424]">
    <node index="0" text="" resource-id="com.example.shop:id/row_card" class="androidx.cardview.widget.CardView" package="com.example.shop" content-desc="" clickable="true" enabled="true" bounds="[42,1240][1038,1466]">
      <node index="0" text="Blue Notebook" resource-id="com.example.shop:id/row_title" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[84,1291][644,1341]" />
    </node>
    <node index="1" text="" resource-id="com.example.shop:id/cart_bar" class="android.view.ViewGroup" package="com.example.shop" content-desc="" clickable="true" enabled="true" bounds="[21,1319][1059,1445]" />
  </node>
</hierarchy>
XML

cat > "$T/item.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8'?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.shop" clickable="false" enabled="true" bounds="[0,0][1080,2424]">
    <node index="0" text="" resource-id="com.example.shop:id/recent_card" class="androidx.cardview.widget.CardView" package="com.example.shop" content-desc="" clickable="true" enabled="true" bounds="[42,1473][893,1747]">
      <node index="0" text="Viewed recently" resource-id="com.example.shop:id/recent_label" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[84,1515][851,1577]" />
      <node index="1" text="Large" resource-id="com.example.shop:id/recent_value" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[84,1598][851,1641]" />
    </node>
    <node index="1" text="Size" resource-id="com.example.shop:id/section_title" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[42,1845][1059,1901]" />
    <node index="2" text="" resource-id="" class="android.view.ViewGroup" package="com.example.shop" content-desc="" clickable="true" enabled="true" bounds="[0,1962][1080,2124]">
      <node index="0" text="" resource-id="com.example.shop:id/choice_radio" class="android.widget.RadioButton" package="com.example.shop" content-desc="" checkable="true" checked="true" clickable="false" enabled="true" bounds="[42,2001][126,2085]" />
      <node index="1" text="Small" resource-id="com.example.shop:id/choice_label" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[168,2015][954,2071]" />
    </node>
    <node index="3" text="" resource-id="" class="android.view.ViewGroup" package="com.example.shop" content-desc="" clickable="true" enabled="true" bounds="[0,2130][1080,2292]">
      <node index="0" text="" resource-id="com.example.shop:id/choice_radio" class="android.widget.RadioButton" package="com.example.shop" content-desc="" checkable="true" checked="false" clickable="false" enabled="true" bounds="[42,2169][126,2253]" />
      <node index="1" text="Large" resource-id="com.example.shop:id/choice_label" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[168,2183][954,2239]" />
    </node>
    <node index="4" text="" resource-id="com.example.shop:id/add_button" class="android.widget.Button" package="com.example.shop" content-desc="" clickable="true" enabled="true" bounds="[42,2171][1038,2297]">
      <node index="0" text="Add to cart" resource-id="com.example.shop:id/add_label" class="android.widget.TextView" package="com.example.shop" content-desc="" clickable="false" enabled="true" bounds="[84,2203][356,2266]" />
    </node>
  </node>
</hierarchy>
XML

echo "== find must not hand back a point another view is sitting on"
# The row's own centre is 540,1353 — inside the cart bar. The label's centre
# (364,1316) clears it by three pixels, and that is the whole difference
# between opening the item and opening the cart.
out="$("$PHONE" find "Blue Notebook" --from "$T/store.xml" 2>&1)"
if [ "$out" = "364 1316" ]; then
  ok "an item row under the cart bar resolves to a point that clears it"
else bad "cart-bar occlusion (got: $out, wanted 364 1316)"; fi

out="$("$PHONE" find "Large" --after "Size" --from "$T/item.xml" 2>&1)"
if [ "$out" = "540 2136" ]; then
  ok "an option row under Add-to-cart resolves above the button"
else bad "footer occlusion (got: $out, wanted 540 2136)"; fi
# ...and the naive answer, the one that would have added the item, is gone.
if printf '%s' "$out" | grep -q "2211"; then
  bad "find still returns the point inside add_button"
else ok "the point inside add_button is never returned"; fi

echo "== find must show the ambiguity rather than picking silently"
out="$("$PHONE" find "Large" --all --from "$T/item.xml" 2>&1)"
if printf '%s' "$out" | grep -q "recent_card" && printf '%s' "$out" | grep -q "2136"; then
  ok "--all lists the recently-viewed decoy AND the real option"
else bad "find --all candidates (got: $out)"; fi
# Without --after, the decoy wins on tree order. That is not a bug to hide:
# it is why --after exists, and the test pins the behaviour so it stays visible.
out="$("$PHONE" find "Large" --from "$T/item.xml" 2>&1)"
if [ "$out" = "467 1610" ]; then
  ok "an unqualified match takes the first candidate, decoy and all"
else bad "unqualified find (got: $out)"; fi

echo "== --after scopes a match to one section"
out="$("$PHONE" find "Viewed recently" --after "Size" --from "$T/item.xml" 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then ok "--after excludes what is above the header"
else bad "--after did not exclude an earlier match (got: $out)"; fi

echo "== look must show which option is actually selected"
out="$("$PHONE" look --from "$T/item.xml" 2>&1)"
if printf '%s' "$out" | grep -q "\[x\] Small" \
   && printf '%s' "$out" | grep -q "\[ \] Large"; then
  ok "look reads checkable state from a sibling node"
else bad "look option state (got: $out)"; fi

echo "== look must warn where a tap would land somewhere else"
out="$("$PHONE" look --from "$T/store.xml" --all 2>&1)"
if printf '%s' "$out" | grep -q "1316"; then
  ok "look prints the clear point, not the covered centre"
else bad "look occlusion-safe coordinates (got: $out)"; fi

echo "== --raw is the way back to the old, unguarded behaviour"
out="$("$PHONE" find "Blue Notebook" --raw --from "$T/store.xml" 2>&1)"
if [ "$out" = "540 1353" ]; then ok "--raw returns the geometric centre"
else bad "--raw (got: $out, wanted 540 1353)"; fi
out="$("$PHONE" find "Nonexistent Label" --from "$T/ui.xml" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -qE "^[0-9]+ [0-9]+$"; then
  ok "a miss exits non-zero and emits NO coordinates (never a blind tap)"
else bad "find miss must not yield coordinates (rc=$rc out=$out)"; fi

echo "== find: disabled elements are never offered as targets"
out="$("$PHONE" find "Disabled thing" --from "$T/ui.xml" 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then ok "disabled element is not a tap target"
else bad "disabled element was offered (out=$out)"; fi

echo "== notifs: the universal inbox, newest first, junk-free"
out="$("$PHONE" notifs --from "$T/notifs.json" 2>&1)"
if printf '%s' "$out" | grep -q "Bob Tanaka" && printf '%s' "$out" | grep -q "Alice Moreau"; then
  ok "notifs lists real messages"
else bad "notifs listing (got: $out)"; fi
first="$(printf '%s' "$out" | grep -nE "Bob Tanaka|Alice Moreau" | head -1)"
if printf '%s' "$first" | grep -q "Bob Tanaka"; then
  ok "notifs is newest-first (10:02 Bob before 09:15 Alice)"
else bad "notifs ordering (got: $first)"; fi

echo "== notifs --app: filter to one app by friendly name"
out="$("$PHONE" notifs --from "$T/notifs.json" --app whatsapp 2>&1)"
if printf '%s' "$out" | grep -q "Bob Tanaka" && ! printf '%s' "$out" | grep -q "Example Bank"; then
  ok "--app whatsapp maps to com.whatsapp and filters"
else bad "--app filter (got: $out)"; fi

echo "== notifs --since: only what arrived after a timestamp"
out="$("$PHONE" notifs --from "$T/notifs.json" --since "2026-08-23 09:00:00" 2>&1)"
all="$("$PHONE" notifs --from "$T/notifs.json" 2>&1)"
if printf '%s' "$out" | grep -q "Bob Tanaka" && ! printf '%s' "$out" | grep -q "Storage almost full" \
   && printf '%s' "$all" | grep -q "Storage almost full"; then
  ok "--since drops older notifications"
else bad "--since filter (got: $out)"; fi

echo "== notifs --json stays machine-readable for the agent"
out="$("$PHONE" notifs --from "$T/notifs.json" --json 2>&1)"
if printf '%s' "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert isinstance(d,list) and d and 'packageName' in d[0]
print('ok')" 2>/dev/null | grep -q ok; then
  ok "--json emits parseable JSON"
else bad "--json output (got: $out)"; fi

echo "== device verbs degrade honestly with no device attached"
out="$(PHONE_NO_DEVICE=1 "$PHONE" say "hello" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qiE "no device|not available|termux"; then
  ok "say without a device fails loudly, never silently"
else bad "no-device degradation (rc=$rc out=$out)"; fi

echo "== say and listen go through termux-api, and open no other connection"
# A listener that writes down every connection stands on the port the bridge
# would be reached on, and the termux tools are stubs that leave a mark when
# they run.
FB="$T/fakebridge.py"
cat > "$FB" <<'PY'
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(4)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    with open(sys.argv[2], "a") as f:
        f.write("connected\n")
    c.close()
PY
python3 "$FB" "$T/fb.port" "$T/fb.log" & FBPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/fb.port" ] && break; sleep 0.2; done
RT="$T/voice-stub"; mkdir -p "$RT"
printf '#!/bin/sh\nprintf "%%s" "$*" > "%s/spoke"\n' "$RT" > "$RT/termux-tts-speak"
printf '#!/bin/sh\necho "hi there"\n' > "$RT/termux-speech-to-text"
chmod +x "$RT/termux-tts-speak" "$RT/termux-speech-to-text"
out="$(PATH="$RT:$PATH" PHONE_BRIDGE_PORT="$(cat "$T/fb.port")" \
       PHONE_BRIDGE_TOKEN=0123456789abcdef0123456789abcdef "$PHONE" say "hello" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$RT/spoke" 2>/dev/null)" = "hello" ]; then
  ok "say speaks through termux-tts-speak"
else bad "say did not reach termux (rc=$rc out=$out spoke=$(cat "$RT/spoke" 2>/dev/null))"; fi
out="$(PATH="$RT:$PATH" PHONE_BRIDGE_PORT="$(cat "$T/fb.port")" \
       PHONE_BRIDGE_TOKEN=0123456789abcdef0123456789abcdef "$PHONE" listen 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "hi there" ]; then
  ok "listen hears through termux-speech-to-text"
else bad "listen did not reach termux (rc=$rc out=$out)"; fi
if [ ! -s "$T/fb.log" ]; then
  ok "and neither of them opened a connection on the bridge port"
else bad "say/listen connected to the bridge port ($(wc -l < "$T/fb.log" | tr -d ' ') connection(s))"; fi
kill $FBPID 2>/dev/null; wait $FBPID 2>/dev/null

echo "== reply --list is a read of personal data, and is recorded as one"
# It prints who has written, from which app, and it wrote no ledger row while
# `notifs`, reading the same kind of thing, did. Recorded the way notifs is:
# a count, never the senders. A bridge that answers one `list`, invented rows.
RL="$T/reply-list"; mkdir -p "$RL"
cat > "$RL/bridge.py" <<'PY'
import json, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(4)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
c, _ = s.accept()
req = json.loads(c.makefile().readline())
ok = req.get("op") == "list" and req.get("token") == sys.argv[2]
rows = [{"key": "0|com.example.chat|1|null|10001", "package": "com.example.chat",
         "title": "Alice Moreau", "repliable": True},
        {"key": "0|com.example.mail|2|null|10002", "package": "com.example.mail",
         "title": "Example Bank", "repliable": False}]
c.sendall((json.dumps({"ok": ok, "notifications": rows}) + "\n").encode())
c.close()
PY
RTOK=0123456789abcdef0123456789abcdef
python3 "$RL/bridge.py" "$RL/port" "$RTOK" & RLPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$RL/port" ] && break; sleep 0.2; done
out="$(PHONE_BRIDGE_PORT="$(cat "$RL/port")" PHONE_BRIDGE_TOKEN="$RTOK" \
       PHONE_LEDGER="$RL/l.jsonl" "$PHONE" reply --list 2>&1)"; rc=$?
kill $RLPID 2>/dev/null; wait $RLPID 2>/dev/null
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "Alice Moreau" \
   && ! printf '%s' "$out" | grep -q "Example Bank"; then
  ok "reply --list shows only what can be replied to"
else bad "reply --list (rc=$rc out=$out)"; fi
if python3 -c "
import json
rows=[json.loads(l) for l in open('$RL/l.jsonl') if l.strip()]
a=rows[-1]
assert a['verb']=='reply' and a['kind']=='read', a
assert a['detail']=={'list': True, 'n': 1}, a
assert 'Alice' not in json.dumps(rows), rows
" 2>/dev/null; then
  ok "and the read is recorded, as a count, never the senders"
else bad "reply --list not recorded as a read ($(cat "$RL/l.jsonl" 2>/dev/null))"; fi

echo "== level-1 first: app/media control must survive adb being OFF"
# Android turns wireless debugging off on network change or idle, so the CORE
# experience cannot depend on adb. These verbs build a deep link and hand it to
# termux-open-url (Termux:API), which needs no adb at all.
out="$("$PHONE" play "a song about the rain" --print-url 2>&1)"
if printf '%s' "$out" | grep -q "music.youtube.com" && printf '%s' "$out" | grep -q "a+song+about+the+rain"; then
  ok "play builds a ytmusic deep link (url-encoded)"
else bad "play url (got: $out)"; fi

out="$("$PHONE" play "hello" --app spotify --print-url 2>&1)"
if printf '%s' "$out" | grep -qi "spotify"; then ok "play --app spotify targets spotify"
else bad "play spotify url (got: $out)"; fi

out="$("$PHONE" open whatsapp --print-url 2>&1)"
if printf '%s' "$out" | grep -qiE "whatsapp|wa.me"; then ok "open resolves an app to its deep link"
else bad "open app deep link (got: $out)"; fi

out="$("$PHONE" open "https://example.com/x?a=1" --print-url 2>&1)"
if printf '%s' "$out" | grep -q "https://example.com/x?a=1"; then ok "open passes a url through unchanged"
else bad "open url passthrough (got: $out)"; fi

out="$("$PHONE" open definitely-not-an-app --print-url 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then ok "open of an unknown app fails honestly"
else bad "open unknown app should fail (out=$out)"; fi

echo "== whatsapp: a phone number + text becomes a prefilled chat link"
out="$("$PHONE" msg whatsapp --to "+15555550142" --text "on my way" --print-url 2>&1)"
if printf '%s' "$out" | grep -q "15555550142" && printf '%s' "$out" | grep -q "on%20my%20way"; then
  ok "msg builds a wa.me link with encoded text"
else bad "msg wa.me link (got: $out)"; fi

echo "== multiline messages are NOT lost (the known termux-api empty-content bug)"
# termux-notification-list returns content:"" for MessagingStyle notifications
# — exactly the group-chat case — but still fills `lines`. Dropping those
# would silently hide the most important messages on the phone.
out="$("$PHONE" notifs --from "$T/notifs.json" --app whatsapp 2>&1)"
if printf '%s' "$out" | grep -q "Hiking club" && printf '%s' "$out" | grep -q "moved the start to 9"; then
  ok "a group chat with empty content still shows its message lines"
else bad "multiline recovery (got: $out)"; fi

echo "== the ledger: every action leaves a trace, at the only chokepoint there is"
# Full two-way agency is safe because it is ACCOUNTABLE, not because it is
# gated. Every capability flows through this CLI, so this CLI is where the
# record gets written — an agent cannot act on the phone without logging it.
LEDGER="$T/actions.jsonl"
# A FAILED send must be recorded too — "I tried to message Bob and could not"
# is exactly the kind of thing the record exists to preserve.
PHONE_LEDGER="$LEDGER" PHONE_NO_DEVICE=1 "$PHONE" msg whatsapp --to "+15555550142" \
  --text "some message" --send >/dev/null 2>&1
if [ -s "$LEDGER" ] && python3 -c "
import json,sys
rows=[json.loads(l) for l in open('$LEDGER') if l.strip()]
a=rows[-1]
assert a['verb']=='msg', a
assert 'some message' in json.dumps(a), a
assert a.get('ts') and a.get('kind')=='act', a
assert a['detail']['sent'] is False, a
assert 'fail' in str(a.get('result','')).lower(), a
print('ok')" 2>/dev/null | grep -q ok; then
  ok "an attempted action appends a structured entry — failures included"
else bad "ledger append (got: $(cat "$LEDGER" 2>/dev/null | tail -1))"; fi

echo "== reads of PERSONAL data are logged too, but marked as reads"
PHONE_LEDGER="$LEDGER" "$PHONE" notifs --from "$T/notifs.json" >/dev/null 2>&1
if python3 -c "
import json
rows=[json.loads(l) for l in open('$LEDGER') if l.strip()]
r=[x for x in rows if x['verb']=='notifs']
assert r, 'no notifs entry'
assert r[-1]['kind']=='read', r[-1]
print('ok')" 2>/dev/null | grep -q ok; then
  ok "reading the inbox is recorded as kind=read (it is someone's private mail)"
else bad "read logging"; fi

echo "== mechanical reads do NOT flood the ledger"
before=$(wc -l < "$LEDGER")
PHONE_LEDGER="$LEDGER" "$PHONE" find "Send" --from "$T/ui.xml" >/dev/null 2>&1
PHONE_LEDGER="$LEDGER" "$PHONE" ui --from "$T/ui.xml" >/dev/null 2>&1
after=$(wc -l < "$LEDGER")
if [ "$before" = "$after" ]; then
  ok "ui/find are mechanical and stay out of the record"
else bad "ledger noise (grew $before -> $after)"; fi

echo "== phone log reads the ledger back"
out="$(PHONE_LEDGER="$LEDGER" "$PHONE" log --limit 5 2>&1)"
if printf '%s' "$out" | grep -q "msg"; then ok "phone log renders recent actions"
else bad "phone log (got: $out)"; fi
out="$(PHONE_LEDGER="$LEDGER" "$PHONE" log --json 2>&1)"
if printf '%s' "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin); assert isinstance(d,list) and d; print('ok')" 2>/dev/null | grep -q ok; then
  ok "phone log --json is machine-readable (anything can render it)"
else bad "phone log --json"; fi

echo "== msg --send: the two-way loop, and it must never fake success"
out="$(PHONE_NO_DEVICE=1 "$PHONE" msg whatsapp --to "+15555550142" --text "hi" --send 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qiE "adb|device|cannot"; then
  ok "--send without a shell fails loudly (it cannot tap, so it must not claim it sent)"
else bad "msg --send no-device honesty (rc=$rc out=$out)"; fi

echo "== find --id: resource-id beats a label (labels move between releases)"
out="$("$PHONE" find --id "com.whatsapp:id/send" --from "$T/ui.xml" 2>&1)"
if printf '%s' "$out" | grep -q "950" && printf '%s' "$out" | grep -q "2050"; then
  ok "find --id resolves a resource-id to coordinates"
else bad "find --id (got: $out)"; fi

echo "== screen --out - streams to stdout (no picture left on disk)"
if grep -q 'out_path == "-"' "$PHONE" && \
   grep -q "stdout.buffer.write" "$PHONE"; then
  ok "screen supports streaming to stdout for a controller"
else bad "screen --out - missing"; fi

echo "== watchdog: the phone heals itself, because Android will keep killing it"
# Termux dies on network changes and hard sleeps. A shell loop gets killed
# too, so the watchdog registers with Android's own JobScheduler — the one
# scheduler the OS actually honours.
#
# The steps are the design's, exactly and in order: wakelock, sshd, shizuku
# (with the tier notice), shelld on the default lane, and adb only when
# PHONE_ADB_ADDR says where to dial — printed as `adb-` otherwise. The list is
# compared whole, so a step that should not be there fails it as surely as a
# missing one.
out="$(PHONE_NO_DEVICE=1 "$PHONE" watchdog --print-only 2>&1)"
steps="$(printf '%s\n' "$out" | awk '/^[^ ]/{printf "%s ", $1}')"
if [ "$steps" = "wakelock sshd shizuku shelld adb- " ]; then
  ok "a pass is exactly: wakelock, sshd, shizuku, shelld, and adb skipped"
else bad "watchdog steps (got: '$steps')"; fi
if printf '%s' "$out" | grep -qi "wake-lock\|wakelock"; then
  ok "the heal pass re-takes the wakelock"
else bad "watchdog wakelock (got: $out)"; fi
wd_self="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PHONE")"
shelld_cmd="$(printf '%s\n' "$out" | grep -A1 '^shelld' | tail -1)"
case "$shelld_cmd" in
  *"PHONE_LANE= "*"$wd_self shelld --start"*) ok "shelld is started by THIS cli, on the default lane" ;;
  *) bad "shelld step command (got: $shelld_cmd)" ;;
esac
if printf '%s' "$out" | grep -q '^adb- .*PHONE_ADB_ADDR'; then
  ok "a skipped adb step says what would turn it on"
else bad "adb skip note (got: $out)"; fi
out="$(PHONE_NO_DEVICE=1 PHONE_ADB_ADDR='<phone-ip>:5555' "$PHONE" watchdog --print-only 2>&1)"
steps="$(printf '%s\n' "$out" | awk '/^[^ ]/{printf "%s ", $1}')"
if [ "$steps" = "wakelock sshd shizuku shelld adb " ]; then
  ok "with PHONE_ADB_ADDR set, adb becomes the fifth step"
else bad "watchdog steps with adb (got: '$steps')"; fi
if printf '%s' "$out" | grep -A1 '^adb ' | grep -q 'adb connect "$PHONE_ADB_ADDR"'; then
  ok "the heal pass reconnects adb at the configured address"
else bad "watchdog adb (got: $out)"; fi

out="$(PHONE_NO_DEVICE=1 "$PHONE" watchdog --install --print-only 2>&1)"
if printf '%s' "$out" | grep -q "termux-job-scheduler"; then
  ok "install registers with Android's JobScheduler (survives process death)"
else bad "watchdog install (got: $out)"; fi
if printf '%s' "$out" | grep -q -- "--persisted true"; then
  ok "the job is persisted, so it survives a reboot too"
else bad "watchdog not persisted (got: $out)"; fi
if printf '%s' "$out" | grep -q -- "--job-id 7137" \
   && printf '%s' "$out" | grep -q "/.local/bin/parallel-root-watchdog.sh" \
   && printf '%s' "$out" | grep -q '.local/state/parallel-root/watchdog.log'; then
  ok "it is job 7137, running parallel-root-watchdog.sh into its own log"
else bad "watchdog job id / script / log (got: $out)"; fi
out="$(PHONE_NO_DEVICE=1 PHONE_WATCHDOG_JOB_ID=4242 "$PHONE" watchdog --install --print-only 2>&1)"
if printf '%s' "$out" | grep -q -- "--job-id 4242"; then
  ok "PHONE_WATCHDOG_JOB_ID moves the job"
else bad "PHONE_WATCHDOG_JOB_ID ignored (got: $out)"; fi
out="$(PHONE_NO_DEVICE=1 PHONE_WATCHDOG_JOB_ID=soon "$PHONE" watchdog --install --print-only 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then ok "a job id that is not a number is refused"
else bad "bad job id accepted (rc=$rc out=$out)"; fi

echo "== a watchdog pass runs the steps it prints, and says which one failed"
# Run for real against stubs: the termux tools, pgrep/sshd (never the real
# sshd), a `timeout` (absent on a stock Mac), and a rish that answers or does
# not. The shelld step is genuine — it starts this CLI's daemon on a socket
# of the suite's own.
WD="$T/wd"; mkdir -p "$WD/bin"
for t in termux-wake-lock termux-tts-speak pgrep sshd; do
  printf '#!/bin/sh\nexit 0\n' > "$WD/bin/$t"
done
printf '#!/bin/sh\necho "post $*" >> "%s/notices"\n' "$WD" > "$WD/bin/termux-notification"
printf '#!/bin/sh\necho "clear $*" >> "%s/notices"\n' "$WD" > "$WD/bin/termux-notification-remove"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$WD/bin/timeout"
printf '#!/bin/sh\nexit 0\n' > "$WD/rish-up"
printf '#!/bin/sh\nexit 1\n' > "$WD/rish-down"
chmod +x "$WD/bin/"* "$WD/rish-up" "$WD/rish-down"
wdpass(){   # $1 = the rish this pass finds
  PATH="$WD/bin:$PATH" PHONE_RISH="$1" PHONE_SHELL_SOCK="$WD/shell.sock" \
    PHONE_SHELL_ARGV=sh PHONE_LEDGER="$WD/ledger.jsonl" "$PHONE" watchdog 2>&1
}
out="$(wdpass "$WD/rish-up")"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "wakelock sshd shizuku shelld adb-" ]; then
  ok "a healthy pass prints every step, with adb skipped"
else bad "healthy watchdog pass (rc=$rc out=$out)"; fi
if [ -S "$WD/shell.sock" ]; then ok "and its shelld step really started the daemon"
else bad "the shelld step started nothing"; fi
if [ ! -s "$WD/ledger.jsonl" ]; then ok "a clean pass writes nothing to the ledger"
else bad "a clean pass wrote: $(cat "$WD/ledger.jsonl")"; fi
if grep -q "^clear phone-tier" "$WD/notices" 2>/dev/null; then
  ok "a live shell tier clears the tier notice"
else bad "tier notice not cleared ($(cat "$WD/notices" 2>/dev/null))"; fi

# The pass that matters most: one that lands while a driver holds the screen
# and somebody's long command has the daemon busy. A daemon that cannot answer
# `true` within five seconds may be busy rather than dead, and the leases live
# only in its memory, so a pass that replaced it would hand the held display to
# the next driver who asked.
wdsh(){ PHONE_SHELL_SOCK="$WD/shell.sock" PHONE_LEDGER="$WD/ledger.jsonl" "$PHONE" "$@"; }
wd_pid="$(cat "$WD/shell.sock.pid" 2>/dev/null || echo 0)"
PHONE_ACTOR=bob wdsh lease acquire --ttl 600 >/dev/null 2>&1
wdsh sh 'sleep 8' >/dev/null 2>&1 & busy=$!
sleep 1
out="$(wdpass "$WD/rish-up")"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "wakelock sshd shizuku shelld adb-" ]; then
  ok "a pass that lands on a busy daemon still reads healthy"
else bad "watchdog pass on a busy daemon (rc=$rc out=$out)"; fi
# Asked once the long command is done, so that whatever daemon now answers on
# this socket has had all the time it needs to write its pidfile.
holder="$(wdsh lease status 2>&1)"
case "$holder" in
  "bob "*) ok "a lease held across that pass survives it" ;;
  *) bad "the lease did not survive a watchdog pass (status: $holder)" ;;
esac
PHONE_ACTOR=intruder wdsh lease acquire >/dev/null 2>&1; rc=$?
if [ $rc -eq 5 ]; then ok "so a second driver is still refused the display"
else bad "a second driver took a held display after a watchdog pass (rc=$rc)"; fi
wait "$busy" 2>/dev/null
if [ "$(cat "$WD/shell.sock.pid" 2>/dev/null || echo 0)" = "$wd_pid" ] \
   && [ "$wd_pid" -gt 1 ] && kill -0 "$wd_pid" 2>/dev/null; then
  ok "and that pass left the busy daemon running instead of binding over it"
else bad "the busy daemon was replaced ($wd_pid -> $(cat "$WD/shell.sock.pid" 2>/dev/null))"; fi
PHONE_ACTOR=bob wdsh lease release >/dev/null 2>&1

# A dead shell tier: shizuku fails, and the shelld step does not run at all.
# The daemon's shell IS rish, so starting one now would only serve failures.
out="$(wdpass "$WD/rish-down")"; rc=$?
if [ "$out" = "wakelock sshd shizuku! shelld- adb-" ]; then
  ok "a dead shell tier is marked shizuku!, and shelld is skipped"
else bad "failing watchdog pass (rc=$rc out=$out)"; fi
if grep -q "^post .*--id phone-tier" "$WD/notices" 2>/dev/null; then
  ok "and raises the tier notice on the phone"
else bad "tier notice not raised ($(cat "$WD/notices" 2>/dev/null))"; fi
if python3 -c "
import json
rows=[json.loads(l) for l in open('$WD/ledger.jsonl') if l.strip()]
a=rows[-1]
assert a['verb']=='watchdog' and a['rc']==1, a
assert 'shizuku' in a['result'], a
" 2>/dev/null; then
  ok "and the failure is in the ledger, as a failure"
else bad "watchdog failure not recorded ($(cat "$WD/ledger.jsonl" 2>/dev/null))"; fi
PHONE_SHELL_SOCK="$WD/shell.sock" "$PHONE" shelld --stop >/dev/null 2>&1
# A phone with no rish at all (the adb-only kind) must not be told its shell
# daemon is healthy. Nothing is running now, and a shelld step that ran would
# stand one up on this socket — the suite's daemon is a plain sh.
out="$(wdpass "$WD/no-such-rish")"; rc=$?
if [ "$out" = "wakelock sshd shizuku! shelld- adb-" ] && [ ! -e "$WD/shell.sock" ]; then
  ok "with no rish, shelld is skipped, never reported healthy"
else bad "no-rish watchdog pass (rc=$rc out=$out socket=$(ls "$WD/shell.sock" 2>&1))"; fi

echo "== the ledger's integrity claim must hold for EVERY sensitive verb"
# The claim in bin/phone is that an agent cannot act on the phone without
# leaving a trace. That was false: camera capture, GPS, clipboard, mic and
# key-events all recorded nothing — and `where` (location) was listed in the
# policy comment as a logged read while its own function never called record().
missing="$(python3 -c "
import re
src = open('$PHONE').read()
bad = []
for v in ('cmd_key','cmd_open','cmd_media','cmd_photo','cmd_notify',
          'cmd_clip','cmd_listen','cmd_where','cmd_tap','cmd_type','cmd_say'):
    m = re.search(r'^def %s\(.*?(?=^def |\Z)' % v, src, re.S|re.M)
    if not m or 'record(' not in m.group(0):
        bad.append(v)
print(' '.join(bad))
")"
if [ -z "$missing" ]; then
  ok "every sensitive verb records (camera, gps, clipboard, mic, keys, launches)"
else bad "verbs act with NO ledger entry:$missing"; fi

echo "== shizuku is preferred over adb, and adb is only a fallback"
# Shizuku holds shell UID over Binder IPC: no port, no connection, nothing
# for Android to switch off. adb is the fragile path that kept dying, so it
# must never be REQUIRED when Shizuku is present.
if grep -q "def have_rish" "$PHONE" && grep -q "def dev_shell" "$PHONE"; then
  ok "there is a single device-shell entry point with a shizuku path"
else bad "no dev_shell/have_rish abstraction"; fi

# every place that used to hard-require adb must now accept either tier
# Grep for adb_ready()/need_adb() OUTSIDE the functions allowed to fall back
# to adb. The old assertion looked only for need_adb() and passed vacuously
# while cmd_msg spelled the same check out inline — a test weaker than its
# own headline, which is how the contradiction survived.
stray="$(python3 -c "
import re
src = open('$PHONE').read()
allowed = ('dev_shell', 'have_shell', '_probe_shell', 'cmd_screen', 'launch',
           'adb', 'adb_ready', 'need_adb')
bad = []
for m in re.finditer(r'^def (\w+)\(.*?(?=^def |\Z)', src, re.S|re.M):
    name, body = m.group(1), m.group(0)
    if name in allowed:
        continue
    if 'adb_ready(' in body or 'need_adb()' in body:
        bad.append(name)
print(' '.join(bad))
")"
if [ -z "$stray" ]; then ok "no verb hard-requires adb any more"
else bad "verbs still requiring adb directly:$stray"; fi

out="$(PHONE_NO_DEVICE=1 "$PHONE" tap 10 10 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "shizuku"; then
  ok "with no device at all, the error names shizuku as the fix"
else bad "no-shell error should mention shizuku (rc=$rc out=$out)"; fi

echo "== bulk data is READ FROM A FILE, never streamed back through rish"
# Measured: rish truncates its stdout at a pipe-buffer boundary — a UI dump
# came back as exactly 8192 bytes. So the privileged side WRITES to /sdcard
# and the unprivileged side READS the file directly. Streaming large output
# back through rish is the bug, not the network transport.
if grep -q "def dev_read" "$PHONE"; then
  ok "there is a file-based path for bulk device data"
else bad "no dev_read helper"; fi
if grep -q "8192\|truncat" "$PHONE"; then
  ok "the truncation hazard is documented where it bites"
else bad "truncation hazard undocumented"; fi

echo "== a persistent shell, because the spawn IS the cost"
# Measured on the device: every rish invocation costs ~1.1s to start
# app_process and load its dex, while the command itself takes milliseconds.
# Paying that per verb is what made the agent feel glacial. One long-lived
# shell fed over a socket removes it.
SOCK="$T/shell.sock"
PHONE_SHELL_SOCK="$SOCK" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.4; done
if [ -S "$SOCK" ]; then ok "shelld starts and listens on a socket"
else bad "shelld did not create $SOCK"; fi

out="$(PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "echo hello-from-persistent" 2>&1 | tail -1)"
if [ "$out" = "hello-from-persistent" ]; then ok "a command round-trips through the persistent shell"
else bad "shelld round trip (got: $out)"; fi

# state must persist across calls — that is the point of one shell
PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "MARKER=stateful" >/dev/null 2>&1
out="$(PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "echo \$MARKER" 2>&1 | tail -1)"
if [ "$out" = "stateful" ]; then ok "the shell is the SAME process across calls"
else bad "shell state not preserved (got: $out)"; fi

# exit codes have to survive, or callers cannot tell success from failure
PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "true" >/dev/null 2>&1; a=$?
PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "(exit 7)" >/dev/null 2>&1; b=$?
if [ "$a" = "0" ] && [ "$b" = "7" ]; then ok "exit codes survive the socket"
else bad "exit codes lost (true=$a exit7=$b)"; fi

# A command CAN kill the shell (`exit`, a crash). The daemon must outlive it,
# or one bad command silently bricks every later call.
PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "exit 3" >/dev/null 2>&1
out="$(PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "echo survived" 2>&1 | tail -1)"
if [ "$out" = "survived" ]; then ok "the daemon respawns a shell that died"
else bad "daemon bricked after its shell exited (got: $out)"; fi

# output containing the sentinel must not truncate the response
out="$(PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "echo a; echo b; echo c" 2>&1 | tr '\n' ',')"
if printf '%s' "$out" | grep -q "a,b,c"; then ok "multi-line output comes back whole"
else bad "multiline through shelld (got: $out)"; fi

big="$(PHONE_SHELL_SOCK="$SOCK" "$PHONE" sh "seq 1 5000" 2>&1 | wc -l | tr -d ' ')"
if [ "$big" = "5000" ]; then ok "large output is not truncated at a buffer boundary"
else bad "large output truncated (got $big lines, wanted 5000)"; fi

PHONE_SHELL_SOCK="$SOCK" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== a FAILED ui dump must never serve the previous screen"
# uiautomator dump fails routinely (animating surface, secure window, screen
# off). Writing to a fixed path meant those failures silently returned the
# LAST screen, and `find` then handed out coordinates for something no longer
# there — the agent taps a real button believing it saw it.
STUB="$T/stubbin"; mkdir -p "$STUB"
printf '#!/bin/sh\ncase "$1" in\n  dump) exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$STUB/uiautomator"
printf '#!/bin/sh\nexit 0\n' > "$STUB/mkdir_ok"
chmod +x "$STUB/uiautomator"
SOCK2="$T/stale.sock"
PHONE_SHELL_SOCK="$SOCK2" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK2" ] && break; sleep 0.4; done
out="$(PATH="$STUB:$PATH" PHONE_SHELL_SOCK="$SOCK2" "$PHONE" ui 2>&1)"; rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -qE "^[0-9]+,[0-9]+"; then
  ok "a failed dump exits non-zero and emits NO screen content"
else bad "STALE SCREEN served after a failed dump (rc=$rc out=$(printf '%s' "$out" | head -2))"; fi
PHONE_SHELL_SOCK="$SOCK2" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== the liveness check must not cost a process spawn"
if grep -q "_SHELL_OK" "$PHONE" && \
   grep -A6 "def _probe_shell" "$PHONE" | grep -q "shelld_call"; then
  ok "have_shell is memoised and asks the daemon before spawning anything"
else bad "have_shell still probes by spawning"; fi

echo "== a hung command must not wedge the daemon for everyone else"
# The accept loop is single-threaded: without a deadline, one command that
# never returns (a uiautomator dump on a screen that never goes idle) blocks
# every later client forever, making the fast path slower than the spawn path
# it replaced.
SOCK3="$T/wedge.sock"
PHONE_SHELL_SOCK="$SOCK3" PHONE_SHELL_ARGV=sh PHONE_SHELL_DEADLINE=3 \
  "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK3" ] && break; sleep 0.4; done
start=$(date +%s)
PHONE_SHELL_SOCK="$SOCK3" "$PHONE" sh "sleep 30" >/dev/null 2>&1; hrc=$?
mid=$(date +%s)
out="$(PHONE_SHELL_SOCK="$SOCK3" "$PHONE" sh "echo recovered" 2>&1 | tail -1)"
end=$(date +%s)
if [ $((mid-start)) -le 12 ]; then ok "a hung command is abandoned at the deadline ($((mid-start))s)"
else bad "hung command was not bounded ($((mid-start))s)"; fi
if [ "$out" = "recovered" ] && [ $((end-mid)) -le 12 ]; then
  ok "the daemon still serves the NEXT client promptly after a hang"
else bad "daemon wedged after a hang (out=$out took $((end-mid))s)"; fi
PHONE_SHELL_SOCK="$SOCK3" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== a daemon must not outlive its socket"
# Measured on a controller: 730 `phone shelld` processes, 727 of them orphaned
# to init, some 13 hours old, holding 5GB of swap between them. Every one was
# created the same way: --stop unlinked the socket and printed "stopped"
# without ever signalling the process, which then sat in accept() forever on a
# name nothing could reach, still holding its shell child. Six per test run,
# and the suite runs often.
# `kill 0` signals the CALLER'S OWN PROCESS GROUP. A missing pidfile leaves
# dpid=0, and the first failing assertion then took the entire suite down with
# `Killed: 9`. Every signal below goes through these, which treat anything
# under 2 as "no such daemon".
alivep(){ [ "${1:-0}" -gt 1 ] && kill -0 "$1" 2>/dev/null; }
reap(){ [ "${1:-0}" -gt 1 ] && kill -9 "$1" 2>/dev/null; return 0; }

REAP="$T/reap.sock"
PHONE_SHELL_SOCK="$REAP" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$REAP" ] && break; sleep 0.4; done
if [ -f "$REAP.pid" ] && alivep "$(cat "$REAP.pid" 2>/dev/null)"; then
  ok "the daemon records a pid a stopper can actually signal"
else bad "no usable pidfile at $REAP.pid"; fi
dpid="$(cat "$REAP.pid" 2>/dev/null || echo 0)"
if alivep "$dpid"; then
  PHONE_SHELL_SOCK="$REAP" "$PHONE" shelld --stop >/dev/null 2>&1
  gone=no
  for i in 1 2 3 4 5 6 7 8 9 10; do
    alivep "$dpid" || { gone=yes; break; }; sleep 0.4
  done
  if [ "$gone" = yes ]; then ok "--stop ENDS the daemon, it does not just hide it"
  else bad "daemon $dpid survived --stop (this is the orphan leak)"; reap "$dpid"; fi
else
  bad "--stop unverifiable: no live daemon pid to watch"
  PHONE_SHELL_SOCK="$REAP" "$PHONE" shelld --stop >/dev/null 2>&1
fi

# The other half of the leak: a daemon whose socket was taken out from under
# it (by --stop's unlink, or by a second --start binding the same path) can
# never be reached again, so nothing will ever close it. It has to notice.
ORPH="$T/orphan.sock"
PHONE_SHELL_SOCK="$ORPH" PHONE_SHELL_ARGV=sh PHONE_SHELLD_TICK=1 \
  "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$ORPH" ] && break; sleep 0.4; done
opid="$(cat "$ORPH.pid" 2>/dev/null || echo 0)"
if alivep "$opid"; then
  rm -f "$ORPH"                     # exactly what the old --stop did
  gone=no
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    alivep "$opid" || { gone=yes; break; }; sleep 0.5
  done
  if [ "$gone" = yes ]; then ok "a daemon that loses its socket exits instead of lingering"
  else bad "orphaned daemon $opid is still running"; reap "$opid"; fi
else
  bad "orphan reaping unverifiable: no live daemon pid to watch"
  rm -f "$ORPH"
fi

# And prevention: starting while one is already live must reuse it, not bind
# over the top and leave the incumbent unreachable.
DUP="$T/dup.sock"
PHONE_SHELL_SOCK="$DUP" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$DUP" ] && break; sleep 0.4; done
first="$(cat "$DUP.pid" 2>/dev/null || echo 0)"
PHONE_SHELL_SOCK="$DUP" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
sleep 1
second="$(cat "$DUP.pid" 2>/dev/null || echo 0)"
if [ "$first" = "$second" ] && alivep "$first"; then
  ok "a second --start reuses the live daemon instead of orphaning it"
else bad "second --start replaced the daemon ($first -> $second)"; fi
out="$(PHONE_SHELL_SOCK="$DUP" "$PHONE" sh "echo still-here" 2>&1 | tail -1)"
if [ "$out" = "still-here" ]; then ok "and the reused daemon still serves"
else bad "reused daemon stopped serving (got: $out)"; fi
PHONE_SHELL_SOCK="$DUP" "$PHONE" shelld --stop >/dev/null 2>&1

# A daemon that answers while its shell does not (Shizuku stopped, rish still
# there) is reported, not replaced: its leases are real, and a fresh daemon
# would start the same shell into the same state.
DEAD="$T/dead.sock"
PHONE_SHELL_SOCK="$DEAD" PHONE_SHELL_ARGV=false "$PHONE" shelld --start >/dev/null 2>&1; rc=$?
dead_pid="$(cat "$DEAD.pid" 2>/dev/null || echo 0)"
if [ $rc -eq 4 ] && alivep "$dead_pid"; then
  ok "a daemon whose shell does not answer is reported as a failure (exit 4)"
else bad "dead-shell start (rc=$rc pid=$dead_pid)"; fi
PHONE_SHELL_SOCK="$DEAD" PHONE_ACTOR=bob "$PHONE" lease acquire >/dev/null 2>&1
PHONE_SHELL_SOCK="$DEAD" PHONE_SHELL_ARGV=false "$PHONE" shelld --start >/dev/null 2>&1; rc=$?
if [ $rc -eq 4 ] && [ "$(cat "$DEAD.pid" 2>/dev/null)" = "$dead_pid" ] \
   && PHONE_SHELL_SOCK="$DEAD" "$PHONE" lease status 2>&1 | grep -q "^bob "; then
  ok "and a second --start leaves it, and the lease it holds, alone"
else bad "a dead-shell daemon was replaced or lost its lease (rc=$rc)"; fi
PHONE_SHELL_SOCK="$DEAD" "$PHONE" shelld --stop >/dev/null 2>&1
alivep "$dead_pid" && reap "$dead_pid"

# No shell to keep at all: no rish, as on a phone that only has adb. A daemon
# that dies there must not leave its names behind — a socket and a pidfile
# are what a later --start would read as a healthy daemon.
NR="$T/norish.sock"
out="$(PHONE_SHELL_SOCK="$NR" "$PHONE" shelld --start 2>&1)"; rc=$?
if [ $rc -eq 3 ] && [ ! -e "$NR" ] && [ ! -e "$NR.pid" ]; then
  ok "with no rish, --start fails (exit 3) and leaves no socket or pidfile"
else bad "no-rish start (rc=$rc out=$out left: $(ls "$NR"* 2>/dev/null))"; fi

# A pidfile outlives a daemon that was killed outright, and its number goes
# to whatever starts next. The stranger runs in a session of its own, so a
# regression here kills only it, never this suite's process group.
STR="$T/reused.sock"
python3 -c 'import os, time; os.setsid(); time.sleep(30)' & stranger=$!
sleep 0.3
printf '%s\n' "$stranger" > "$STR.pid"
PHONE_SHELL_SOCK="$STR" "$PHONE" shelld --stop >/dev/null 2>&1
if alivep "$stranger"; then
  ok "--stop does not signal a process that merely inherited a stale pid"
else bad "--stop killed an unrelated process named by a stale pidfile"; fi
reap "$stranger"; wait "$stranger" 2>/dev/null

echo "== the regex tier must not answer a request to ACT"
# Measured: "open whatsapp and send bob a message about dinner" was answered
# by the fast path with a count of notifications by app — the word "message"
# matched the notifications pattern, so a request to SEND one was silently
# swallowed by a read of ones RECEIVED. The person is told what is in their
# inbox and Bob never hears from them.
#
# The patterns are matched on nouns with no regard for whether the sentence is
# a question or an instruction. Asserted on the DECISION rather than the
# answer, so it holds with no device attached.
cat > "$T/fastmatch.py" <<'PY'
import importlib.machinery, importlib.util, sys
spec = importlib.util.spec_from_loader(
    "phonemod", importlib.machinery.SourceFileLoader("phonemod", sys.argv[1]))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    got = m.fast_match(line)
    print("%s\t%s" % ("none" if got is None else got[1].__name__, line))
PY

printf '%s\n' \
  "open whatsapp and send bob a message about dinner" \
  "send alice a message saying I am running late" \
  "text carol that I will call her tomorrow" \
  "reply to that message for me" \
  "tell the reviewer to merge the branch" \
  > "$T/act.txt"
if out="$(python3 "$T/fastmatch.py" "$PHONE" < "$T/act.txt" 2>&1)" \
   && [ "$(printf '%s' "$out" | grep -vc '^none')" = "0" ]; then
  ok "a request to send, text, reply or tell is left to the router"
else bad "the regex tier answered a request to ACT: $(printf '%s' "$out" | grep -v '^none' | head -2)"; fi

# Instructions that merely MENTION a read's noun. Matched on the noun, each was
# answered as a question about it, exit 0: the battery for battery saver and a
# car to charge, the calendar for an event to add, a count for "clear", and
# the phone's clock for a shop's hours. The patterns match whole questions.
printf '%s\n' \
  "turn on battery saver" \
  "power off the phone" \
  "remind me to charge the car" \
  "add lunch to my calendar" \
  "open the calendar app" \
  "clear my notifications" \
  "what time does the store close" \
  "what is the battery level of my headphones" \
  "play something by the band from the festival" \
  > "$T/act2.txt"
if out="$(python3 "$T/fastmatch.py" "$PHONE" < "$T/act2.txt" 2>&1)" \
   && [ "$(printf '%s' "$out" | grep -vc '^none')" = "0" ]; then
  ok "an instruction that only mentions a read's noun is left to the router"
else bad "the regex tier answered an instruction as a question: $(printf '%s' "$out" | grep -v '^none' | head -3)"; fi

# The other half, and the reason this cannot just be "decline anything with a
# verb": the read questions and the media controls must still match, and
# match the RIGHT handler, fillers and punctuation and all.
while IFS='|' read -r want q; do
  printf '%s\t%s\n' "$want" "$q"
done > "$T/read.txt" <<'EOF'
_spoken_notifs|any messages for me
_spoken_notifs|what notifications do I have
_spoken_battery|what is my battery
_spoken_battery|how much battery do I have left
_spoken_playing|what is playing
_spoken_playing|What’s playing right now?
_spoken_time|what time is it
_spoken_time|hey, can you tell me what time it is?
_spoken_date|what's today's date
_spoken_cal|what's on my calendar today
_media_pause|pause the music
_media_next|skip this track
_media_play|resume
EOF
cut -f2 "$T/read.txt" > "$T/read-q.txt"
if out="$(python3 "$T/fastmatch.py" "$PHONE" < "$T/read-q.txt" 2>&1)" \
   && [ "$out" = "$(cat "$T/read.txt")" ]; then
  ok "questions and media controls still take the fast path, to the right handler"
else bad "fast path stopped matching things it should: $(printf '%s\n' "$out" | diff - "$T/read.txt" | head -4)"; fi

echo "== ask: the router is a command you choose, and there is no default"
# The middle tier is `--router CMD` or $PHONE_ROUTER, split like a shell line
# with the brief appended as ONE final argument. The answer is the last
# non-empty stdout line that does not open with `[` and does not mention
# "tokens used". Exit 0 answered, 4 escalate, 5 the router itself failed.
RTR="$T/router"; mkdir -p "$RTR"
# A router that answers the way agents print: progress first, a bracketed
# status line, the answer, then a token count. It also writes down what it
# was given — the argument count, and each argument in a file of its own.
cat > "$RTR/answers" <<EOF
#!/bin/sh
rm -f "$RTR"/arg.*
printf '%s\n' "\$#" > "$RTR/argc"
i=0
for a in "\$@"; do i=\$((i+1)); printf '%s' "\$a" > "$RTR/arg.\$i"; done
echo "thinking it over"
echo "[2026-01-01T00:00:00] status: done"
echo "Michelangelo painted it."
echo "tokens used: 1234"
EOF
printf '#!/bin/sh\necho "considering"\necho "ESCALATE"\n' > "$RTR/escalates"
printf '#!/bin/sh\necho "Traceback: something broke"\nexit 3\n' > "$RTR/crashes"
printf '#!/bin/sh\necho "[only a status line]"\n' > "$RTR/silent"
chmod +x "$RTR/answers" "$RTR/escalates" "$RTR/crashes" "$RTR/silent"
Q="who painted the sistine chapel"

out="$(PHONE_LEDGER="$RTR/l.jsonl" "$PHONE" ask --router "$RTR/answers" "$Q" 2>"$RTR/err")"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "Michelangelo painted it." ]; then
  ok "a router's answer comes back on stdout, exit 0"
else bad "router answer (rc=$rc out=$out err=$(cat "$RTR/err"))"; fi
if grep -q "^tier: router (answers, " "$RTR/err"; then
  ok "and the tier it came from is on stderr"
else bad "router tier line (got: $(cat "$RTR/err"))"; fi
if [ "$(cat "$RTR/argc" 2>/dev/null)" = "1" ]; then
  ok "the brief is appended as ONE argument"
else bad "router got $(cat "$RTR/argc" 2>/dev/null) arguments, wanted 1"; fi
self="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PHONE")"
brief="$RTR/arg.1"
if grep -qF "Question: $Q" "$brief" && grep -qF "ESCALATE" "$brief" \
   && grep -qF "You may run: $self <verb>" "$brief" \
   && grep -qF "battery | media --current" "$brief"; then
  ok "the brief carries the question, the ESCALATE rule, this CLI's path and its read verbs"
else bad "router brief (got: $(head -c 600 "$brief" 2>/dev/null))"; fi
if python3 -c "
import json
rows=[json.loads(l) for l in open('$RTR/l.jsonl') if l.strip()]
a=rows[-1]
assert a['verb']=='ask' and a['kind']=='read', a
assert a['detail']['tier']=='router' and a['detail']['router']=='answers', a
" 2>/dev/null; then
  ok "a routed answer is recorded, naming the router"
else bad "ask not recorded ($(cat "$RTR/l.jsonl" 2>/dev/null))"; fi

out="$("$PHONE" ask --router "$RTR/answers --flag 'two words'" "$Q" 2>/dev/null)"
argv_seen="[$(cat "$RTR/arg.1" 2>/dev/null)][$(cat "$RTR/arg.2" 2>/dev/null)]"
if [ "$(cat "$RTR/argc")" = "3" ] && [ "$argv_seen" = "[--flag][two words]" ] \
   && grep -qF "Question: $Q" "$RTR/arg.3"; then
  ok "CMD is split like a shell line, quotes and all, and the brief comes last"
else bad "router split (argc=$(cat "$RTR/argc") argv=$argv_seen)"; fi

out="$(PHONE_ROUTER="$RTR/answers" "$PHONE" ask "$Q" 2>/dev/null)"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "Michelangelo painted it." ]; then
  ok "\$PHONE_ROUTER is the router when --router is not given"
else bad "PHONE_ROUTER ignored (rc=$rc out=$out)"; fi
out="$(PHONE_ROUTER="$RTR/answers" "$PHONE" ask --router '' "$Q" 2>/dev/null)"; rc=$?
if [ $rc -eq 4 ] && [ -z "$out" ]; then ok "--router '' means none, even with \$PHONE_ROUTER set"
else bad "--router '' (rc=$rc out=$out)"; fi

out="$("$PHONE" ask --router "$RTR/escalates" "$Q" 2>/dev/null)"; rc=$?
if [ $rc -eq 4 ] && [ -z "$out" ]; then ok "a router that says ESCALATE exits 4, with nothing on stdout"
else bad "router escalate (rc=$rc out=$out)"; fi

# A router that could not run is NOT an escalation decision: escalating on a
# crash would silently send everything to the expensive tier.
out="$("$PHONE" ask --router "$RTR/not-there" "$Q" 2>&1)"; rc=$?
if [ $rc -eq 5 ] && printf '%s' "$out" | grep -q "router failed"; then
  ok "a router that cannot be run exits 5"
else bad "missing router (rc=$rc out=$out)"; fi
out="$("$PHONE" ask --router "$RTR/crashes" "$Q" 2>/dev/null)"; rc=$?
if [ $rc -eq 5 ] && [ -z "$out" ]; then
  ok "a router that fails exits 5, and its output is never read out as the answer"
else bad "crashing router (rc=$rc out=$out)"; fi
out="$("$PHONE" ask --router "$RTR/silent" "$Q" 2>/dev/null)"; rc=$?
if [ $rc -eq 5 ]; then ok "a router that prints no answer line exits 5"
else bad "silent router (rc=$rc out=$out)"; fi
out="$("$PHONE" ask --router "$RTR/answers 'unbalanced" "$Q" 2>&1)"; rc=$?
if [ $rc -eq 5 ] && ! printf '%s' "$out" | grep -q "unbalanced"; then
  ok "a router command that cannot be split exits 5, without echoing it"
else bad "unsplittable router (rc=$rc out=$out)"; fi

out="$("$PHONE" ask "$Q" 2>"$RTR/err")"; rc=$?
if [ $rc -eq 4 ] && [ -z "$out" ] && grep -qi "escalate" "$RTR/err"; then
  ok "no router, and a question the fast tier declines: exit 4"
else bad "no-router escalate (rc=$rc out=$out err=$(cat "$RTR/err"))"; fi

# --no-fast skips tier 1. Needs a fast tier that CAN answer, so a local shell
# stands in for the phone's clock.
ASOCK="$T/ask.sock"
PHONE_SHELL_SOCK="$ASOCK" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$ASOCK" ] && break; sleep 0.4; done
out="$(PHONE_SHELL_SOCK="$ASOCK" "$PHONE" ask --router "$RTR/answers" "what time is it" 2>"$RTR/err")"; rc=$?
if [ $rc -eq 0 ] && grep -q "^tier: fast" "$RTR/err" && printf '%s' "$out" | grep -q "^It's "; then
  ok "the fast tier answers what it can, before any router"
else bad "fast tier (rc=$rc out=$out err=$(cat "$RTR/err"))"; fi
out="$(PHONE_SHELL_SOCK="$ASOCK" "$PHONE" ask --no-fast --router "$RTR/answers" "what time is it" 2>"$RTR/err")"; rc=$?
if [ $rc -eq 0 ] && grep -q "^tier: router" "$RTR/err"; then
  ok "--no-fast goes straight to the router"
else bad "--no-fast (rc=$rc out=$out err=$(cat "$RTR/err"))"; fi
PHONE_SHELL_SOCK="$ASOCK" "$PHONE" shelld --stop >/dev/null 2>&1

# On the phone itself, with no PHONE_DEVICE, the fast tier answers from the
# phone's own verbs. The battery, notification and calendar handlers used to
# answer only over ssh from a controller: `phone battery` printed the level
# while `phone ask "what is my battery level"` escalated.
ON="$T/on-phone"; mkdir -p "$ON/bin"
printf '#!/bin/sh\nexit 0\n' > "$ON/bin/termux-tts-speak"
printf '#!/bin/sh\necho %s\n' "'{\"percentage\": 51, \"status\": \"DISCHARGING\", \"plugged\": \"UNPLUGGED\"}'" \
  > "$ON/bin/termux-battery-status"
printf '#!/bin/sh\ncat "%s"\n' "$T/notifs.json" > "$ON/bin/termux-notification-list"
# `content` for the calendar read, on the PATH of a local daemon's shell.
cat > "$ON/bin/content" <<'EOF'
#!/bin/sh
echo "Row: 0 title=Standup, begin=1788760000000, end=1788761800000, eventLocation=, allDay=0"
EOF
chmod +x "$ON/bin/"*
OSOCK="$T/on.sock"
PATH="$ON/bin:$PATH" PHONE_SHELL_SOCK="$OSOCK" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
onphone(){ PATH="$ON/bin:$PATH" PHONE_SHELL_SOCK="$OSOCK" PHONE_LEDGER="$ON/l.jsonl" "$PHONE" ask "$1" 2>"$ON/err"; }
out="$(onphone "what is my battery level")"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "51 percent, discharging." ] && grep -q "^tier: fast" "$ON/err"; then
  ok "on the phone, the fast tier answers the battery"
else bad "battery on the phone (rc=$rc out=$out err=$(cat "$ON/err"))"; fi
out="$(onphone "any messages for me")"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "5 notifications: 3 from whatsapp, 1 from gm, 1 from system." ]; then
  ok "and the notifications"
else bad "notifications on the phone (rc=$rc out=$out err=$(cat "$ON/err"))"; fi
out="$(onphone "what's on my calendar today")"; rc=$?
case "$rc $out" in
  "0 One thing today: Standup at "*) ok "and the calendar" ;;
  *) bad "calendar on the phone (rc=$rc out=$out err=$(cat "$ON/err"))" ;;
esac
PHONE_SHELL_SOCK="$OSOCK" "$PHONE" shelld --stop >/dev/null 2>&1

# The battery's state is named, never guessed from substrings: "charg" in the
# status called FULL said "discharging", and NOT_CHARGING said "charging".
out="$(PHONE_PATH="$PHONE" python3 - <<PY
$PRELUDE
for line in ("100%  FULL  PLUGGED_AC", "80%  NOT_CHARGING  PLUGGED_USB",
             "64%  CHARGING  PLUGGED_AC", "51%  DISCHARGING  UNPLUGGED",
             "33%  UNKNOWN  UNPLUGGED"):
    m.run = lambda argv, timeout=30, want_bytes=False, line=line: (0, line)
    print(m._spoken_battery(None))
PY
)"
if [ "$out" = "100 percent, fully charged.
80 percent, plugged in but not charging.
64 percent, charging.
51 percent, discharging.
33 percent." ]; then
  ok "full, not charging, charging and discharging are each said as what they are"
else bad "battery states (got: $out)"; fi

# Driven from a controller, `ask` stands up no forward of its own. Stood up
# first, a phone that was away ended a question only the router needed with
# exit 3, which ask does not have. A fast handler that needs the phone's
# shell asks for the link itself, and when the phone is away it declines —
# it must not answer from some other adb-attached device instead.
AW="$T/away"; mkdir -p "$AW"
cat > "$AW/adb" <<EOF
#!/bin/sh
case "\$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  *) echo "\$*" >> "$AW/adb-used"; echo "12:00|Monday 01 January" ;;
esac
EOF
chmod +x "$AW/adb"
out="$(PATH="$AW:$PATH" TMPDIR="$AW" PHONE_LEDGER="$AW/l.jsonl" \
       "$PHONE" --device test-phone ask --router "$RTR/answers" "$Q" 2>"$AW/err")"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "Michelangelo painted it." ]; then
  ok "with the phone away, a question for the router is still answered"
else bad "router question with the phone away (rc=$rc out=$out err=$(cat "$AW/err"))"; fi
out="$(PATH="$AW:$PATH" TMPDIR="$AW" PHONE_LEDGER="$AW/l.jsonl" \
       "$PHONE" --device test-phone ask --router "$RTR/answers" "what time is it" 2>"$AW/err")"; rc=$?
if [ $rc -eq 0 ] && grep -q "^tier: router" "$AW/err" && [ ! -e "$AW/adb-used" ]; then
  ok "and a fast question falls through to it, never to another adb device"
else bad "fast question with the phone away (rc=$rc out=$out err=$(cat "$AW/err") adb: $(cat "$AW/adb-used" 2>/dev/null))"; fi
out="$(PATH="$AW:$PATH" TMPDIR="$AW" PHONE_LEDGER="$AW/l.jsonl" \
       "$PHONE" --device test-phone ask "what time is it" 2>"$AW/err")"; rc=$?
if [ $rc -eq 4 ] && [ ! -e "$AW/adb-used" ]; then
  ok "with no router either, it escalates (exit 4), not exit 3"
else bad "no router, phone away (rc=$rc out=$out err=$(cat "$AW/err"))"; fi

out="$(PHONE_PATH="$PHONE" python3 - <<PY
$PRELUDE
b = m.router_brief("is it raining", "test-phone")
print("ok" if " --device test-phone <verb>" in b else b)
PY
)"
if [ "$out" = "ok" ]; then ok "driven from a controller, the brief names the device too"
else bad "router brief with a device (got: $out)"; fi

echo "== type must preserve real text, and admit what it dropped"
# The strip-regex silently deleted apostrophes, =, $, <, >, |, backtick and
# more, then reported success by counting WORDS WHOSE EXIT CODE WAS 0 — which
# says nothing about what arrived. An actuator that lies about what it typed
# is worse than one that fails.
# Assert the ROUND TRIP through a shell parser, not the literal bytes:
# shlex correctly emits 'Don'"'"'t' for Don't, which is how a shell actually
# delivers an apostrophe. Checking for the literal would fail on correct code.
out="$("$PHONE" type --print-only "Don't panic: x=2 & y=7 (ok)" 2>&1)"
if printf '%s' "$out" | python3 -c "
import shlex, sys
words = []
for line in sys.stdin.read().splitlines():
    if line.startswith('input text '):
        words.append(shlex.split(line)[-1])
got = ' '.join(words)
want = \"Don't panic: x=2 & y=7 (ok)\"
print('OK' if got == want else 'GOT:' + got)
" | grep -q '^OK$'; then
  ok "type delivers the exact text through the shell (apostrophes, =, &)"
else bad "type mangles text (got: $out)"; fi
if printf '%s' "$out" | grep -q "input text"; then
  ok "--print-only shows the exact input text argv"
else bad "--print-only should show the argv (got: $out)"; fi

echo "== output with NO trailing newline must not hang the shell daemon"
# The sentinel is emitted on its own line after the command. If the command's
# output does not end in a newline, the sentinel lands on the SAME line and
# the startswith() check never matches — so the daemon waited the full
# deadline on every such command. Measured: `head -c 100 file` took 75.20s
# and returned rc=124, with the data present the whole time.
SOCK4="$T/nonl.sock"
PHONE_SHELL_SOCK="$SOCK4" PHONE_SHELL_ARGV=sh PHONE_SHELL_DEADLINE=8 \
  "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK4" ] && break; sleep 0.4; done
st=$(date +%s)
out="$(PHONE_SHELL_SOCK="$SOCK4" "$PHONE" sh "printf 'no-trailing-newline'" 2>&1)"; rc=$?
el=$(( $(date +%s) - st ))
if [ "$rc" = "0" ] && [ $el -le 5 ]; then
  ok "a command with no trailing newline returns immediately (${el}s)"
else bad "no-newline output hung or failed (rc=$rc ${el}s out=$out)"; fi
if printf '%s' "$out" | grep -q "no-trailing-newline"; then
  ok "and its output is intact"
else bad "no-newline output lost (got: $out)"; fi
# and a normal newline-terminated command must not gain a spurious blank line
out="$(PHONE_SHELL_SOCK="$SOCK4" "$PHONE" sh "echo one; echo two" 2>&1 | tr '\n' ',')"
if [ "$out" = "one,two," ] || [ "$out" = "one,two" ]; then
  ok "newline-terminated output is unchanged (no injected blank line)"
else bad "newline handling changed output (got: $out)"; fi
PHONE_SHELL_SOCK="$SOCK4" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== launching an app needs no shell tier (am start works as the app UID)"
# Measured on the device: `am start -n <component>` succeeds from Termux with
# shizuku down and adb off. So losing the shell tier must not cost app
# launching — it is the first step of most tasks.
if grep -q "am start -n" "$PHONE" && \
   grep -B6 "am start -n" "$PHONE" | grep -qiE "level 1|no shell|without a shell"; then
  ok "open has a level-1 launch path documented at the call site"
else bad "open still requires a shell to launch an app"; fi

echo "== the watchdog must REPORT a lost tier, not just degrade silently"
# Shizuku's service can stop while the phone stays up (observed: up 2 days,
# service gone). Level 1 keeps working, which is by design — but if nobody is
# told, the phone quietly loses half its capability and the agent starts
# refusing things for reasons the human cannot see.
if python3 -c "
import re
src = open('$PHONE').read()
m = re.search(r'WATCHDOG_STEPS = \((.*?)\n\)', src, re.S)
import sys
sys.exit(0 if (m and 'shizuku' in m.group(1)) else 1)
"; then
  ok "the watchdog checks the shell tier"
else bad "watchdog does not check shizuku"; fi
if grep -q "tier_notice\|termux-notification.*shizuku\|notify_tier" "$PHONE"; then
  ok "a lost shell tier raises a notification the human can act on"
else bad "a lost tier is silent"; fi

echo "== the lease: only one driver may act on the phone at a time"
# Two agents interleaving taps is not a race that produces a wrong pixel; it
# is one agent typing into another's chat. The lease lives in shelld because
# it is on-device and every shell verb already passes through it, so local
# and remote callers are arbitrated alike.
SOCK5="$T/lease.sock"
PHONE_SHELL_SOCK="$SOCK5" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK5" ] && break; sleep 0.4; done
export PHONE_SHELL_SOCK="$SOCK5"

out="$("$PHONE" lease acquire --as alice 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "a free phone can be leased"
else bad "acquire failed (rc=$rc out=$out)"; fi

out="$("$PHONE" lease acquire --as intruder 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "alice"; then
  ok "a second driver is refused, and told who holds it"
else bad "second acquire should fail naming the holder (rc=$rc out=$out)"; fi

out="$("$PHONE" lease acquire --as alice 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "the holder may re-acquire (renew) its own lease"
else bad "holder re-acquire failed (rc=$rc out=$out)"; fi

out="$("$PHONE" lease status 2>&1)"
if printf '%s' "$out" | grep -q "alice"; then ok "status names the holder"
else bad "status (got: $out)"; fi

# A mutating verb from a NON-holder must refuse rather than interleave.
out="$(PHONE_ACTOR=intruder "$PHONE" key HOME 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "lease\|held by"; then
  ok "a mutating verb from a non-holder is refused"
else bad "non-holder was allowed to act (rc=$rc out=$out)"; fi

# Reads stay free: watching must never require taking the wheel.
out="$(PHONE_ACTOR=onlooker "$PHONE" notifs --from "$T/notifs.json" 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "reads are not gated by the lease"
else bad "a read was blocked by the lease (rc=$rc)"; fi

out="$("$PHONE" lease release --as alice 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "the holder can release"
else bad "release failed (rc=$rc out=$out)"; fi
out="$("$PHONE" lease acquire --as intruder 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "and the phone is free again"
else bad "still held after release (rc=$rc out=$out)"; fi

# A crashed holder must not lock the phone forever.
"$PHONE" lease release --as intruder >/dev/null 2>&1
"$PHONE" lease acquire --as ghost --ttl 1 >/dev/null 2>&1
sleep 2
out="$("$PHONE" lease acquire --as alice 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "an expired lease is reclaimable (a crashed holder does not brick the phone)"
else bad "expired lease still held (rc=$rc out=$out)"; fi
"$PHONE" lease release --as alice >/dev/null 2>&1
"$PHONE" shelld --stop >/dev/null 2>&1
unset PHONE_SHELL_SOCK

echo "== the ledger must be a TRACE, not a list of claims"
# "open keep -> opened" says what was attempted and asserted. It does not say
# WHO asked, whether the underlying command actually succeeded, or how long
# it took — so a slow tap and a failed one read identically, and a request
# cannot be followed back to its requester.
LED2="$T/trace.jsonl"
PHONE_LEDGER="$LED2" PHONE_ACTOR=alice PHONE_NO_DEVICE=1 "$PHONE" msg whatsapp \
  --to "+15555550142" --text "trace me" --send >/dev/null 2>&1
if python3 -c "
import json
rows=[json.loads(l) for l in open('$LED2') if l.strip()]
a=rows[-1]
assert a.get('actor')=='alice', 'actor missing: %r' % a
assert isinstance(a.get('ms'), (int,float)), 'ms missing: %r' % a
assert 'rc' in a, 'rc missing: %r' % a
print('ok')" 2>/dev/null | grep -q ok; then
  ok "an entry carries actor, elapsed ms, and an exit code"
else bad "ledger is not a trace (got: $(tail -1 "$LED2" 2>/dev/null))"; fi

out="$(PHONE_LEDGER="$LED2" "$PHONE" log --limit 3 --actor alice 2>&1)"
if printf '%s' "$out" | grep -q "alice"; then
  ok "log can be filtered to one actor (who did this?)"
else bad "log --actor (got: $out)"; fi

echo "== look: the screen an agent can actually afford to read"
# `ui` dumps every node with text — hundreds of lines on a real app, most of
# it container ids the agent can do nothing with. A model paying that on
# every step burns its context on scaffolding. `look` is the same screen,
# summarised: what app, and the things that can actually be acted on.
out="$("$PHONE" look --from "$T/ui.xml" 2>&1)"
if printf '%s' "$out" | grep -qi "whatsapp"; then
  ok "look names the app in the foreground"
else bad "look should name the app (got: $out)"; fi
if printf '%s' "$out" | grep -q "Alice Moreau" && printf '%s' "$out" | grep -q "Send"; then
  ok "look keeps the things you can act on"
else bad "look dropped actionable elements (got: $out)"; fi
if printf '%s' "$out" | grep -qE "^\s*[0-9]+,[0-9]+"; then
  ok "look keeps coordinates so a tap needs no second call"
else bad "look has no coordinates (got: $out)"; fi
# The container ids ui emits (conversation, drag_layer, scrim_view) are
# scaffolding — an agent can do nothing with them and they dominate the dump.
if ! printf '%s' "$out" | grep -q "scrim_view"; then
  ok "look drops container scaffolding"
else bad "look kept scaffolding"; fi
ui_lines=$("$PHONE" ui --from "$T/ui.xml" 2>/dev/null | wc -l | tr -d ' ')
look_lines=$("$PHONE" look --from "$T/ui.xml" 2>/dev/null | wc -l | tr -d ' ')
if [ "$look_lines" -le "$ui_lines" ]; then
  ok "look is no larger than ui ($look_lines vs $ui_lines lines)"
else bad "look is bigger than ui ($look_lines vs $ui_lines)"; fi

echo "== the skill and the CLI must agree"
r="$(python3 "$HERE/tests/check-skill-verbs.py" 2>&1)"
# Prefix, not equality: the checker also names which skill documents it
# covered, and that list grows every time a skill is added.
if [ "${r%% *}" = "agree" ]; then
  ok "every verb the skills teach exists in the CLI"
else bad "$r"; fi

echo "== the skill states the habits that keep an agent honest"
for must in "look" "lease" "Never guess" "capabilities"; do
  if grep -qi -- "$must" "$HERE/plugin/skills/phone/SKILL.md"; then
    ok "skill covers: $must"
  else bad "skill missing: $must"; fi
done

echo "== --device: drive a phone from somewhere else, over a forwarded socket"
# An agent running on the phone itself runs on a slow CPU and keeps losing its
# session. The controller belongs off-device — which only works if the CLI can
# address a remote phone. It does that by forwarding shelld's socket, so sshd
# never forks a shell (the ~0.45s that made this feel slow).
out="$("$PHONE" --device test-phone --print-link 2>&1)"
if printf '%s' "$out" | grep -q "ssh" && printf '%s' "$out" | grep -q -- "-L"; then
  ok "--device knows how to build the forward"
else bad "--print-link (got: $out)"; fi
if printf '%s' "$out" | grep -q "phone-shell.sock"; then
  ok "the forward targets the device's shelld socket"
else bad "forward target wrong (got: $out)"; fi
# A stream-local forward must NOT be handed to an existing mux master: it is
# accepted and silently never created. Measured, and it cost real time.
if printf '%s' "$out" | grep -q "ControlPath=none"; then
  ok "the forward uses a dedicated connection, not the mux"
else bad "forward would be swallowed by an existing master (got: $out)"; fi
out="$("$PHONE" --device "bad name; rm -rf" --print-link 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then ok "a hostile device name is refused"
else bad "device name not validated (out=$out)"; fi

echo "== two drivers racing for the lease: exactly one wins"
# The lease was correct only because shelld's accept loop happens to be
# single-threaded — correctness resting on a distant, unrelated property.
# Make shelld concurrent (the obvious future optimisation) and it goes racy
# with no test failing and nothing erroring; you just occasionally get two
# drivers, which is precisely what it exists to prevent. This asserts the
# invariant itself rather than the property it used to lean on.
SOCK6="$T/race.sock"
PHONE_SHELL_SOCK="$SOCK6" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK6" ] && break; sleep 0.4; done
wins="$(python3 -c "
import subprocess, threading, os
env = dict(os.environ); env['PHONE_SHELL_SOCK'] = '$SOCK6'
won = []
lock = threading.Lock()
def go(name):
    r = subprocess.run(['$PHONE', 'lease', 'acquire', '--as', name],
                       capture_output=True, env=env)
    if r.returncode == 0:
        with lock:
            won.append(name)
threads = [threading.Thread(target=go, args=('driver%d' % i,)) for i in range(8)]
[t.start() for t in threads]; [t.join() for t in threads]
print(len(won))
")"
if [ "$wins" = "1" ]; then ok "8 simultaneous acquires, exactly 1 winner"
else bad "the lease is racy: $wins winners out of 8"; fi
PHONE_SHELL_SOCK="$SOCK6" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== --device must carry the termux-api verbs too, not just shell ones"
# The forwarded socket runs commands at SHELL uid. Termux's own binaries live
# in an app-private prefix that shell uid cannot read, so notifs/say/battery
# cannot ride that path — they have to run as the app, on the device. A
# --device that silently only covered half the verbs would be worse than one
# that covered none, because the failure looks like a broken phone.
out="$("$PHONE" --device test-phone --print-plan notifs --limit 2 2>&1)"
if printf '%s' "$out" | grep -q "ssh" && printf '%s' "$out" | grep -q "notifs"; then
  ok "a termux-api verb is planned to run ON the device"
else bad "termux verb routing (got: $out)"; fi
out="$("$PHONE" --device test-phone --print-plan tap 1 2 2>&1)"
if printf '%s' "$out" | grep -qi "socket\|forward\|local"; then
  ok "a shell verb still takes the fast forwarded path"
else bad "shell verb routing (got: $out)"; fi

echo "== the actor has to cross the ssh hop, or the trace says anon"
# The ledger's whole job is WHO. A termux verb runs on the DEVICE, so it is
# the device's `phone` that writes the record -- and PHONE_ACTOR is an
# environment variable on the CONTROLLER, which ssh does not forward. So
# every notifs/clip/where/photo/listen from a remote controller logged as
# "anon": the reads of personal data, which are exactly the ones the record
# exists for, and exactly the ones that cannot be traced back to who asked.
out="$(PHONE_ACTOR=alice "$PHONE" --device test-phone --print-plan notifs 2>&1)"
if printf '%s' "$out" | grep -q "PHONE_ACTOR=alice"; then
  ok "the remote command carries the actor"
else bad "actor lost across the hop (got: $out)"; fi

# ...and it must survive being a hostile string, since it lands in a shell.
# Grepping the plan is not enough here, and getting this wrong is subtle:
# shlex.quote("PHONE_ACTOR=a; rm") yields "'PHONE_ACTOR=a; rm'", which reads
# as a fully quoted word -- and a word whose NAME part is quoted stops being
# an assignment and becomes a command name. The far shell would hunt for a
# binary called that and never run phone at all. It greps fine and is
# silently broken, so ask a real shell instead: run the planned remote
# string with a stub `phone` on PATH and see what it actually receives.
STUB="$(mktemp -d)"
cat > "$STUB/phone" <<'STUBEOF'
#!/bin/sh
printf 'ACTOR=[%s]\n' "$PHONE_ACTOR"
printf 'ARGV=[%s]\n' "$*"
STUBEOF
chmod +x "$STUB/phone"
EVIL='a; rm -rf /'
plan="$(PHONE_ACTOR="$EVIL" "$PHONE" --device test-phone --print-plan notifs 2>&1)"
# The plan line is "run on the device (...): ssh <opts> <host> <remote>".
# The remote command is everything after the hostname.
remote="${plan#*test-phone }"
got="$(PATH="$STUB:$PATH" sh -c "$remote" 2>&1)"
rm -rf "$STUB"
if [ "$got" = "ACTOR=[$EVIL]
ARGV=[notifs]" ]; then
  ok "a real shell sees the actor as a value and still runs phone"
else bad "hostile actor mangles the far command (got: $got)"; fi

# An unset actor must not send a bare PHONE_ACTOR= that overrides whatever
# the device itself would have said.
out="$(env -u PHONE_ACTOR "$PHONE" --device test-phone --print-plan notifs 2>&1)"
if ! printf '%s' "$out" | grep -q "PHONE_ACTOR"; then
  ok "no actor set means no actor forced on the device"
else bad "empty actor forced across (got: $out)"; fi

echo "== PHONE_REMOTE_BIN names the CLI on the far side, everywhere it is run"
# A phone can carry more than one copy of this CLI, so a controller has to be
# able to say which one it means — in every place it runs itself remotely:
# termux verbs, binary verbs, the remote half of log, and a lane's daemon.
out="$(PHONE_REMOTE_BIN=/opt/pr/bin/phone "$PHONE" --device test-phone --print-plan notifs --limit 2 2>&1)"
case "$out" in
  *"PHONE_DEVICE= /opt/pr/bin/phone notifs --limit 2") ok "a termux verb runs \$PHONE_REMOTE_BIN on the phone" ;;
  *) bad "termux verb remote bin (got: $out)" ;;
esac
out="$("$PHONE" --device test-phone --print-plan notifs 2>&1)"
case "$out" in
  *"PHONE_DEVICE= phone notifs") ok "and plain \`phone\` when it is unset" ;;
  *) bad "default remote bin (got: $out)" ;;
esac
out="$(PHONE_REMOTE_BIN=/opt/pr/bin/phone "$PHONE" --device test-phone --print-plan screen 2>&1)"
case "$out" in
  *"/opt/pr/bin/phone screen --out -"*) ok "a binary verb streams from \$PHONE_REMOTE_BIN too" ;;
  *) bad "binary verb remote bin (got: $out)" ;;
esac
# It is quoted as ONE word, so a path with a space in it still runs, and
# nothing in it is re-parsed by the far shell.
RB="$(mktemp -d)"
mkdir -p "$RB/pr bin"
printf '#!/bin/sh\nprintf "ARGV=[%%s]\\n" "$*"\n' > "$RB/pr bin/phone"
chmod +x "$RB/pr bin/phone"
plan="$(PHONE_REMOTE_BIN="$RB/pr bin/phone" "$PHONE" --device test-phone --print-plan notifs 2>&1)"
remote="${plan#*test-phone }"
got="$(sh -c "$remote" 2>&1)"
if [ "$got" = "ARGV=[notifs]" ]; then
  ok "\$PHONE_REMOTE_BIN with a space in it is still one command"
else bad "remote bin quoting (plan: $plan got: $got)"; fi
# The remote half of log: a stub ssh writes down the command it was given.
cat > "$RB/ssh" <<'SEOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "$last" > "$(dirname "$0")/remote-cmd"
echo '[]'
SEOF
chmod +x "$RB/ssh"
PATH="$RB:$PATH" TMPDIR="$RB" PHONE_REMOTE_BIN=/opt/pr/bin/phone PHONE_LEDGER="$RB/l.jsonl" \
  "$PHONE" --device test-phone log --json >/dev/null 2>&1
got="$(cat "$RB/remote-cmd" 2>/dev/null)"
case "$got" in
  *"/opt/pr/bin/phone log --json --limit 40") ok "the remote half of log asks \$PHONE_REMOTE_BIN for the device's ledger" ;;
  *) bad "log remote bin (got: $got)" ;;
esac
# The phone filters before it limits. Filtered here, after the phone had sent
# its newest 500 rows from anyone, a driver's older rows there vanished behind
# everybody else's, with exit 0.
PATH="$RB:$PATH" TMPDIR="$RB" PHONE_LEDGER="$RB/l.jsonl" \
  "$PHONE" --device test-phone log --json --actor agent-b --kind read --limit 7 >/dev/null 2>&1
got="$(cat "$RB/remote-cmd" 2>/dev/null)"
case "$got" in
  *"phone log --json --limit 7 --kind read --actor agent-b") ok "--actor, --kind and the limit travel to the phone's half" ;;
  *) bad "log filters stayed behind (got: $got)" ;;
esac
# --limit 0 is everything here, but the phone's half is capped, and a half
# that comes back AT the cap may have more behind it: said so, and exit 3, as
# for a phone that could not be read at all.
python3 -c '
import json
print(json.dumps([{"ts": float(i), "verb": "notifs", "kind": "read", "actor": "agent-b",
                   "ms": 1, "rc": 0, "detail": "all"} for i in range(5000)]))' > "$RB/far.json"
cat > "$RB/ssh" <<SEOF
#!/bin/sh
for last; do :; done
printf '%s\n' "\$last" > "$RB/remote-cmd"
cat "$RB/far.json"
SEOF
chmod +x "$RB/ssh"
out="$(PATH="$RB:$PATH" TMPDIR="$RB" PHONE_LEDGER="$RB/l.jsonl" \
       "$PHONE" --device test-phone log --json --limit 0 2>&1 >/dev/null)"; rc=$?
got="$(cat "$RB/remote-cmd" 2>/dev/null)"
case "$got" in
  *"phone log --json --limit 5000") ok "an unlimited log asks the phone for at most its cap" ;;
  *) bad "unlimited log remote command (got: $got)" ;;
esac
if [ $rc -eq 3 ] && printf '%s' "$out" | grep -q "stops at its newest 5000 rows"; then
  ok "and a phone's half that comes back at the cap is reported, exit 3"
else bad "a capped half read as complete (rc=$rc err=$out)"; fi
out="$(PATH="$RB:$PATH" TMPDIR="$RB" PHONE_LEDGER="$RB/l.jsonl" \
       "$PHONE" --device test-phone log --json --limit 20 2>&1 >/dev/null)"; rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
  ok "while a limited log that gets all the rows it asked for is complete"
else bad "a limited log read as partial (rc=$rc err=$out)"; fi
# A lane's daemon is started over ssh by name — the same name.
out="$(PHONE_PATH="$PHONE" PHONE_LANE=alpha PHONE_REMOTE_BIN=/opt/pr/bin/phone TMPDIR="$RB" \
       python3 - 2>"$RB/lane.err" <<PY
$PRELUDE
calls = []
def fake_run(argv, timeout=30, want_bytes=False):
    calls.append(argv)
    return 0, ""
m.run = fake_run
m.shelld_call = lambda *a, **k: None      # no daemon ever answers
m.time.sleep = lambda s: None
try:
    m.ensure_link("test-phone")
except SystemExit:
    pass
starts = [c[-1] for c in calls if c and c[0] == "ssh" and "shelld --start" in c[-1]]
print(starts[0] if starts else "no daemon start among %r" % calls)
PY
)"
if [ "$out" = "PHONE_DEVICE= PHONE_DISPLAY= PHONE_SHELL_SOCK= PHONE_LANE=alpha /opt/pr/bin/phone shelld --start" ]; then
  ok "a lane's daemon is started as \$PHONE_REMOTE_BIN, pinned like every hop"
else bad "lane daemon start (got: $out)"; fi
rm -rf "$RB"

cat > "$T/media.txt" <<'MEDIAEOF'
  Media button session is com.example.player/com.example.player.session/11 (userId=0)
  Sessions Stack - have 3 sessions:
    com.example.player.session com.example.player/com.example.player.session/11 (userId=0)
      ownerPid=21012, ownerUid=10201, userId=0
      package=com.example.player
      launchIntent=PendingIntent{1a2b3c: PendingIntentRecord{4d5e6f com.example.player startActivity}}
      mediaButtonReceiver=null
      active=true
      flags=7
      rating type=0
      controllers: 10
      state=PlaybackState {state=PAUSED(2), position=45793, buffered position=0, speed=0.0, updated=209717132, actions=7339997, custom actions=[Action:mName='Favorite, mIcon=2131232741], active item id=0, error=null}
      audioAttrs=AudioAttributes: usage=USAGE_MEDIA content=CONTENT_TYPE_UNKNOWN
      volumeType=LOCAL, controlType=ABSOLUTE, max=0, current=0, volumeControlId=null
      metadata: size=43, description=Northern Lights, The Example Band, Placeholder Sessions
      queueTitle=null, size=1
    radio-session com.example.radio/radio-session/8 (userId=0)
      ownerPid=24502, ownerUid=10337, userId=0
      package=com.example.radio
      active=true
      flags=3
      controllers: 2
      state=PlaybackState {state=ERROR(7), position=-1, buffered position=0, speed=0.0, updated=133344791, actions=141312, custom actions=[], active item id=-1, error=Please sign in to keep listening.}
      volumeType=LOCAL, controlType=ABSOLUTE, max=0, current=0, volumeControlId=null
      metadata: null
      queueTitle=, size=0
    video_session com.example.video/video_session/10 (userId=0)
      ownerPid=23191, ownerUid=10208, userId=0
      package=com.example.video
      active=false
      flags=3
      controllers: 0
      state=null
      metadata: null
MEDIAEOF

echo "== media: the phone already knows what is playing, structured"
# Driving a music app by dumping the UI tree and tapping a coordinate is the
# computer-use pattern -- the wrong tool when we hold shell UID. dumpsys
# media_session carries the app, the transport state, the position and the
# track, and cmd media_session dispatches transport keys to the right
# session. No screen, no coordinates, works with the display off.
out="$("$PHONE" media --from "$T/media.txt" --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {s["package"]: s for s in d}
pl = by["com.example.player"]
assert pl["state"] == "PAUSED", pl
assert pl["position_ms"] == 45793, pl
assert pl["active"] is True, pl
assert "Northern Lights" in (pl["description"] or ""), pl
ra = by["com.example.radio"]
assert ra["state"] == "ERROR", ra
assert "sign in" in (ra["error"] or "").lower(), ra
assert ra["description"] is None, ra
vi = by["com.example.video"]
assert vi["active"] is False and vi["state"] is None, vi
' 2>/dev/null; then
  ok "media parses sessions: app, state, position, track, error"
else bad "media session parse (got: $out)"; fi

out="$("$PHONE" media --from "$T/media.txt" 2>&1)"
if printf '%s' "$out" | grep -q "Northern Lights" && printf '%s' "$out" | grep -qi "paused"; then
  ok "media prints what is playing in one line a human can read"
else bad "media human output (got: $out)"; fi

# The session that MATTERS is the active one holding real playback, not the
# first one printed, and not the one erroring.
out="$("$PHONE" media --from "$T/media.txt" --current 2>&1)"
if printf '%s' "$out" | grep -q "com.example.player" \
   && ! printf '%s' "$out" | grep -q "radio"; then
  ok "--current picks the real session, not an errored or inactive one"
else bad "--current selection (got: $out)"; fi

# Invented people, invented places, and the comma-inside-a-value shapes that
# break a naive parser: a title listing several names, a location with a
# town in it, and a contact filed surname-first.
cat > "$T/cal.txt" <<'CALEOF'
Row: 0 title=Labor Day, begin=1788739200000, end=1788825600000, eventLocation=, allDay=1
Row: 1 title=Lunch with Alice, Bob, and Carol, begin=1788750000000, end=1788753600000, eventLocation=Corner Cafe, Springfield, allDay=0
Row: 2 title=Standup, begin=1788760000000, end=1788761800000, eventLocation=, allDay=0
CALEOF

cat > "$T/contacts.txt" <<'CONEOF'
Row: 0 display_name=Erin Walsh, data1=+15555550117
Row: 1 display_name=Alice Moreau, data1=+15555550142
Row: 2 display_name=Smith, John, data1=+15555550199
CONEOF

echo "== content-provider rows survive values that contain commas"
# `content query` prints "Row: N k=v, k=v" and does not quote or escape.
# A title of "Lunch with Alice, Bob, and Carol" or a surname-first contact
# "Smith, John" splits into garbage under a naive split on ", ". The keys
# are known -- we chose the projection -- so split on the key boundaries,
# not on commas.
out="$("$PHONE" cal --from "$T/cal.txt" --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
t = [e["title"] for e in d]
assert "Lunch with Alice, Bob, and Carol" in t, t
loc = [e["location"] for e in d if e["title"].startswith("Lunch")][0]
assert loc == "Corner Cafe, Springfield", loc
day = [e for e in d if e["title"] == "Labor Day"][0]
assert day["all_day"] is True, day
assert [e for e in d if e["title"] == "Standup"][0]["location"] is None
' 2>/dev/null; then
  ok "calendar rows parse with commas inside titles and locations"
else bad "calendar row parse (got: $out)"; fi

out="$("$PHONE" contacts --from "$T/contacts.txt" --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {c["name"]: c["number"] for c in d}
assert by["Smith, John"] == "+15555550199", by
assert by["Alice Moreau"] == "+15555550142", by
' 2>/dev/null; then
  ok "contact rows parse with a comma inside the name"
else bad "contact row parse (got: $out)"; fi

echo "== contacts: a name goes in, a number comes out"
# "message Alice" needs a number, and the phone knows it. Reading it off the
# Contacts app's screen would be three taps and a UI dump.
out="$("$PHONE" contacts alice --from "$T/contacts.txt" 2>&1)"
if printf '%s' "$out" | grep -q "+15555550142" \
   && ! printf '%s' "$out" | grep -q "Erin"; then
  ok "contacts search is case-insensitive and filters"
else bad "contacts search (got: $out)"; fi
out="$("$PHONE" contacts "nobody by that name" --from "$T/contacts.txt" 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then
  ok "a contact that is not there exits non-zero (never a wrong number)"
else bad "missing contact must not exit 0 (got: $out)"; fi

echo "== calendar reads are recorded as reads of personal data"
CL="$T/cal-ledger.jsonl"
PHONE_LEDGER="$CL" "$PHONE" cal --from "$T/cal.txt" >/dev/null 2>&1
PHONE_LEDGER="$CL" "$PHONE" contacts alice --from "$T/contacts.txt" >/dev/null 2>&1
if python3 -c "
import json
rows=[json.loads(l) for l in open('$CL') if l.strip()]
verbs={r['verb']: r for r in rows}
assert 'cal' in verbs and verbs['cal']['kind']=='read', rows
assert 'contacts' in verbs and verbs['contacts']['kind']=='read', rows
# the trace must not become a copy of the address book
assert '+15555550142' not in json.dumps(rows), 'ledger leaked a phone number'
" 2>/dev/null; then
  ok "both are logged as reads, and the ledger does not copy the data out"
else bad "provider read logging"; fi

echo "== a screenshot has to be able to cross the hop at all"
# The skill tells the agent: when the tree fails you, take a screenshot and
# look at the picture. From a controller that never worked. Binary cannot
# ride the forwarded socket (shelld carries text), rish is not on the
# controller and adb has no device, so the read came back empty and screen
# died with "screen off or secure surface" -- a diagnosis that sends you to
# unlock a phone that was never the problem. A capability the skill depends
# on, absent in the configuration the skill describes, blamed on the user.
ST="$(mktemp -d)"
cat > "$ST/ssh" <<'SEOF'
#!/bin/sh
# A device that streams a PNG on stdout, as `phone screen --out -` does.
printf '\211PNG\r\n\032\n'
printf 'IHDRfake-image-body'
SEOF
chmod +x "$ST/ssh"
out="$(PATH="$ST:$PATH" TMPDIR="$ST" PHONE_LEDGER="$ST/l.jsonl" \
       "$PHONE" --device test-phone screen --out "$ST/got.png" 2>&1)"; rc=$?
# Compare the magic BYTES. grep skips the line entirely under a UTF-8
# locale, because \x89 is not valid UTF-8 -- it reported no match on a
# file that was perfectly correct.
magic="$(od -An -tx1 -N8 "$ST/got.png" 2>/dev/null | tr -d ' \n')"
if [ $rc -eq 0 ] && [ "$magic" = "89504e470d0a1a0a" ]; then
  ok "screen --device streams the image back and writes it HERE"
else bad "screenshot did not cross the hop (rc=$rc out=$out)"; fi

# The plan must show it running ON the device, not against the socket.
out="$(TMPDIR="$ST" "$PHONE" --device test-phone --print-plan screen 2>&1)"
if printf '%s' "$out" | grep -q "ssh" && printf '%s' "$out" | grep -q -- "--out -"; then
  ok "screen is planned to run on the device, streaming to stdout"
else bad "screen routing (got: $out)"; fi

# Bytes that are not an image must not be written and called a screenshot.
# An ssh error, a login banner, a shell diagnostic on stdout: all non-empty.
cat > "$ST/ssh" <<'SEOF'
#!/bin/sh
echo "Warning: Permanently added something to known hosts."
SEOF
chmod +x "$ST/ssh"
rm -f "$ST/bad.png"
out="$(PATH="$ST:$PATH" TMPDIR="$ST" PHONE_LEDGER="$ST/l2.jsonl" \
       "$PHONE" --device test-phone screen --out "$ST/bad.png" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ ! -f "$ST/bad.png" ]; then
  ok "non-image bytes are refused, and no file is left behind"
else bad "wrote non-image bytes as a screenshot (rc=$rc out=$out)"; fi
rm -rf "$ST"

echo "== media: dispatch goes to the BUTTON session, not the one you meant"
# Found on the device, by watching rather than reasoning:
# `cmd media_session dispatch` takes no session argument. It goes to the
# "media button session" -- the app that last held AUDIO -- which is not
# necessarily the foreground app and not necessarily the one you just
# addressed. With one music app foregrounded, active, and holding a loaded
# queue, `dispatch play` started a DIFFERENT music app and left the first
# frozen at 0.
#
# That breaks a before/after check: before/after was compared on
# `current_session`, which re-ranks after the dispatch. If the dispatch lands
# on a different app, the ranking can hand back a DIFFERENT session
# afterwards, the states differ, and the move gets reported as success --
# crediting one app's playback to another. So the target has to be named,
# and before/after compared on the same package.
out="$("$PHONE" media --from "$T/media.txt" --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
btn = [s for s in d if s.get("media_button")]
assert len(btn) == 1, btn
assert btn[0]["package"] == "com.example.player", btn
others = [s for s in d if not s.get("media_button")]
assert all(s["package"] != "com.example.player" for s in others), others
' 2>/dev/null; then
  ok "the session that will receive a dispatch is identified"
else bad "media button session not identified (got: $out)"; fi

out="$("$PHONE" media --from "$T/media.txt" 2>&1)"
if printf '%s' "$out" | grep -q "<- keys" ; then
  ok "and it is marked in the human view, so nobody has to guess"
else bad "button session unmarked in human output (got: $out)"; fi

# A dispatch that changed nothing was watched and did not happen: a failure,
# exit 4. It used to be 5, which means refused (a held lease, one app one
# display), and a caller reading it would wait for a lease nobody holds.
MD="$T/media-dispatch"; mkdir -p "$MD"
cat > "$MD/adb" <<EOF
#!/bin/sh
case "\$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  shell) case "\$*" in *"dumpsys media_session"*) cat "$T/media.txt" ;; esac; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MD/adb"
out="$(PATH="$MD:$PATH" TMPDIR="$MD" PHONE_LEDGER="$MD/l.jsonl" "$PHONE" media pause 2>&1)"; rc=$?
if [ $rc -eq 4 ] && printf '%s' "$out" | grep -q "did not change"; then
  ok "a transport key that changed nothing exits 4, not 5"
else bad "unconfirmed dispatch (rc=$rc out=$out)"; fi

echo "== the lease gate reads what an invocation does, not just its name"
# By name alone, acts hid behind flags and reads were refused for sharing a
# name with an act: `scan --tap` went through a display somebody else held
# while a bare `tap` there was refused, and `media --current` (a parse of a
# local file, even) and `clip get` exited 5 under another driver's lease.
GS="$T/gate.sock"
PHONE_SHELL_SOCK="$GS" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
PHONE_SHELL_SOCK="$GS" PHONE_ACTOR=bob "$PHONE" lease acquire --ttl 600 >/dev/null 2>&1
GT="$T/gate-termux"; mkdir -p "$GT"
printf '#!/bin/sh\nexit 0\n' > "$GT/termux-tts-speak"
printf '#!/bin/sh\necho "copied text"\n' > "$GT/termux-clipboard-get"
printf '#!/bin/sh\necho set >> "%s/clip-set"\n' "$GT" > "$GT/termux-clipboard-set"
chmod +x "$GT/"*
alice(){ PATH="$GT:$PATH" PHONE_SHELL_SOCK="$GS" PHONE_ACTOR=alice PHONE_LEDGER="$GT/l.jsonl" \
         PHONE_BRIDGE_TOKEN=not-a-token "$PHONE" "$@"; }
out="$(alice scan "Northern Lights" --tap 2>&1)"; rc=$?
if [ $rc -eq 5 ] && printf '%s' "$out" | grep -q "bob"; then
  ok "scan --tap is refused on a display someone else holds"
else bad "scan --tap went through bob's lease (rc=$rc out=$out)"; fi
out="$(alice media --from "$T/media.txt" --current 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "com.example.player"; then
  ok "media's read is not gated"
else bad "media read under a lease (rc=$rc out=$out)"; fi
alice media pause --from "$T/media.txt" >/dev/null 2>&1
[ $? -eq 5 ] && ok "while a transport action is" || bad "media pause was not gated"
out="$(alice clip get 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$out" = "copied text" ]; then
  ok "clip get is not gated"
else bad "clip get under a lease (rc=$rc out=$out)"; fi
alice clip set "new text" >/dev/null 2>&1; rc=$?
if [ $rc -eq 5 ] && [ ! -e "$GT/clip-set" ]; then
  ok "while clip set is, before the clipboard is touched"
else bad "clip set under a lease (rc=$rc)"; fi
# reply sends a message to a person; --list only reads. The token is not one,
# so an ungated --list stops at "the bridge is not reachable" (3) with no
# connection made.
alice reply --list >/dev/null 2>&1
[ $? -eq 3 ] && ok "reply --list is not gated" || bad "reply --list was refused"
alice reply "0|com.example.chat|1|null|10001" "on my way" >/dev/null 2>&1
[ $? -eq 5 ] && ok "while a reply is" || bad "reply went through bob's lease"
# A form that only prints what it would do acts on nothing.
out="$(alice type --print-only "ab cd" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "input text ab"; then
  ok "type --print-only is not gated"
else bad "type --print-only under a lease (rc=$rc out=$out)"; fi
alice open "https://example.com/x" --print-url >/dev/null 2>&1
[ $? -eq 0 ] && ok "nor is open --print-url" || bad "open --print-url was refused"
out="$(PHONE_PATH="$PHONE" python3 - <<PY
$PRELUDE
p = m.build_parser()
for argv in (["scan", "x"], ["scan", "x", "--tap"], ["media"], ["media", "status"],
             ["media", "next"], ["clip", "get"], ["clip", "set", "y"],
             ["reply", "--list"], ["reply", "k", "t"], ["play", "x", "--dry-run"],
             ["msg", "whatsapp", "--to", "1", "--print-url"], ["tap", "1", "2"]):
    print("%s %s" % (" ".join(argv), m.mutates(argv[0], p.parse_args(argv))))
PY
)"
if [ "$out" = "scan x False
scan x --tap True
media False
media status False
media next True
clip get False
clip set y True
reply --list False
reply k t True
play x --dry-run False
msg whatsapp --to 1 --print-url False
tap 1 2 True" ]; then
  ok "the gate's decision, form by form"
else bad "mutates() (got: $out)"; fi
PHONE_SHELL_SOCK="$GS" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== an app name must resolve to THAT app, or to nothing"
# The sharpest bug a device review found, and it is the same class as tapping
# a wrong coordinate: `--app chrome` resolved to
# com.google.android.apps.chromecast.app — Google Home — and printed
# "(no notifications)", which reads as a clean negative about Chrome.
# `open chrome` would have LAUNCHED Google Home.
#
# Two causes, both fixed here:
#   1. resolution ran against `pm list packages -3`, third-party only, so
#      every system app (chrome, youtube, photos, calendar) was invisible —
#      including ones the CLI's own error message advertises as valid.
#   2. on a miss it substring-matched and took the single hit. "chrome" is a
#      substring of "chromecast". Wrong app, full confidence, no warning.
#
# The rule now: match whole dotted SEGMENTS, never substrings, and refuse
# ambiguity by name instead of picking the shortest.
NT="$(mktemp -d)"
mkpkgs() {   # $1 = full `pm list packages` output
  cat > "$NT/adb" <<EOF
#!/bin/sh
while [ "\$1" = "-s" ]; do shift 2; done
case "\$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n'; exit 0 ;;
  shell|exec-out)
    shift
    case "\$*" in
      *"pm list packages -3"*) printf 'package:com.google.android.apps.chromecast.app\n' ;;
      *"pm list packages"*)    printf '$1' ;;
      *resolve-activity*)      printf '%s/.Main\n' "\${*##* }" ;;
      *am\ start*)             exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$NT/adb"
}

# A phone with Google Home and NO Chrome. Asking for chrome must fail.
mkpkgs 'package:com.google.android.apps.chromecast.app\npackage:com.google.android.youtube\n'
out="$(PATH="$NT:$PATH" TMPDIR="$NT" PHONE_LEDGER="$NT/l.jsonl" \
       "$PHONE" open chrome 2>&1)"; rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q "chromecast"; then
  ok "a name that is only a SUBSTRING of another package is refused"
else bad "chrome resolved to the wrong app (rc=$rc out=$out)"; fi

# The same phone: youtube is a SYSTEM package, absent from -3, and must
# still resolve — the old code could not see it at all.
out="$(PATH="$NT:$PATH" TMPDIR="$NT" PHONE_LEDGER="$NT/l2.jsonl" \
       "$PHONE" open youtube 2>&1)"; rc=$?
if ! printf '%s' "$out" | grep -qi "no app matching"; then
  ok "a system package resolves (the list is no longer third-party only)"
else bad "system package unresolvable (rc=$rc out=$out)"; fi

# Genuine ambiguity is named, not silently narrowed to the shortest.
mkpkgs 'package:com.foo.notes\npackage:com.bar.notes\n'
out="$(PATH="$NT:$PATH" TMPDIR="$NT" "$PHONE" open notes 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "com.foo.notes" \
   && printf '%s' "$out" | grep -q "com.bar.notes"; then
  ok "two candidates are both named, and nothing is chosen"
else bad "ambiguity silently resolved (rc=$rc out=$out)"; fi
rm -rf "$NT"

echo "== a large read has to PROVE it arrived intact"
# Found on the device, reproduced here, and localised to our own daemon: the
# persistent shell corrupts large reads. Not truncation — the byte count and
# line count come back EXACTLY right, with a region substituted by content
# from earlier in the stream, sometimes from the PREVIOUS command entirely
# (a run of seq 100001..130000 that opened with '1171'), and once with two
# numbers welded together ('316316676').
#
# Measured over the same 169 KB payload: plain ssh 4/4 clean, shelld 4/4
# corrupt, on-device and over the forward alike. Rate climbs with size —
# clean at 4 KB, half at 9 KB, none at 61 KB.
#
# Why it is dangerous rather than annoying: rc is 0, the length is right, and
# a UI dump still opens with <hierarchy and closes with </hierarchy>. Every
# guard we had passes. XML is merely brittle enough to notice; a corrupted
# package list or dumpsys has nothing to notice with and would be used as
# fact. The UI tree was the canary, not the victim.
IT2="$(mktemp -d)"
cat > "$IT2/md5sum" <<'MEOF'
#!/bin/sh
# Deliberately wrong, every time: the read must never be believed.
echo "00000000000000000000000000000000  $1"
MEOF
chmod +x "$IT2/md5sum"
cat > "$IT2/adb" <<'AEOF'
#!/bin/sh
while [ "$1" = "-s" ]; do shift 2; done
case "$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n'; exit 0 ;;
  shell|exec-out) shift; sh -c "$*"; exit $? ;;
  *) exit 0 ;;
esac
AEOF
chmod +x "$IT2/adb"

out="$(PATH="$IT2:$PATH" TMPDIR="$IT2" PHONE_LEDGER="$IT2/l.jsonl" \
       "$PHONE" sh --checked 'echo hello' 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "corrupt\|did not survive\|integrity"; then
  ok "a read whose checksum never matches fails loudly instead of returning"
else bad "bad checksum was accepted (rc=$rc out=$out)"; fi

# And with a REAL md5sum on PATH, the same path must succeed — otherwise the
# check is just a way to break working reads.
rm -f "$IT2/md5sum"
out="$(PATH="$IT2:$PATH" TMPDIR="$IT2" PHONE_LEDGER="$IT2/l2.jsonl" \
       "$PHONE" sh --checked 'echo hello' 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "hello"; then
  ok "a read whose checksum matches comes back normally"
else bad "verified read broke a good read (rc=$rc out=$out)"; fi
rm -rf "$IT2"

echo "== the device's stderr must not vanish on the way back"
# Found on the device, and it is the signature failure of this whole codebase
# in a new place: a denied `content query` comes back as RC=0 with NO output,
# which is byte-for-byte identical to "readable and empty". The verb built
# specifically to tell those two apart could not tell them apart.
#
# The stub `adb` here is a REAL shell, so the redirection semantics under
# test are the actual ones, not ones asserted about.
ET="$(mktemp -d)"
cat > "$ET/adb" <<'EEOF'
#!/bin/sh
case "$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  shell)   shift; sh -c "$*" ;;
  *) exit 0 ;;
esac
EEOF
chmod +x "$ET/adb"

out="$(PATH="$ET:$PATH" TMPDIR="$ET" PHONE_LEDGER="$ET/l.jsonl" \
       "$PHONE" sh 'echo OUT; echo ERR >&2' 2>/dev/null)"
if printf '%s' "$out" | grep -q "OUT" && printf '%s' "$out" | grep -q "ERR"; then
  ok "phone sh surfaces the device's stderr, not just its stdout"
else bad "device stderr dropped (got: $out)"; fi

# And the load-bearing property of the wrapper itself, exercised by a REAL
# shell rather than an adb stub. Two things have to hold together: stderr
# comes back, AND the command's own exit status survives — a subshell or a
# pipe would give us the wrapper's status instead, which would turn every
# failure into a success at the exact moment we started reading stderr.
if PHONE_PATH="$PHONE" python3 - <<'PYEOF'
import os, pathlib, subprocess
src = pathlib.Path(os.environ["PHONE_PATH"]).read_text()
ns = {}
exec(compile(src.split("def dev_shell(")[0], "phone", "exec"), ns)
merged = ns["merged"]

# stderr arrives
r = subprocess.run(["sh", "-c", merged("echo OUT; echo ERR >&2")],
                   capture_output=True, text=True)
assert "OUT" in r.stdout and "ERR" in r.stdout, r
# exit status is the COMMAND's, not the wrapper's
r = subprocess.run(["sh", "-c", merged("echo boom >&2; exit 7")],
                   capture_output=True, text=True)
assert r.returncode == 7, r.returncode
assert "boom" in r.stdout, r
# and success stays success
r = subprocess.run(["sh", "-c", merged("true")], capture_output=True, text=True)
assert r.returncode == 0, r.returncode
PYEOF
then
  ok "the wrapper returns stderr AND preserves the command's exit status"
else bad "merged() wrapper semantics"; fi
rm -rf "$ET"

echo "== capabilities: ask the device, do not trust a table in a document"
# Every capability fact here is dated. A music app declares
# MEDIA_PLAY_FROM_SEARCH today; shell holds READ_SMS on Android 16 today.
# Written into a skill as fact, both start lying on some future release and
# nothing tells anyone. So the skill teaches METHOD and this verb supplies
# FACTS, live, from the phone in front of you.
#
# The load-bearing distinction is three-valued: yes / no / could-not-check.
# Collapsing "I could not look" into "no" is exactly the bug that made an
# empty package list read as "the app is missing", and an empty SMS table
# read as "SMS is blocked".
CT="$(mktemp -d)"
cat > "$CT/adb" <<'CEOF'
#!/bin/sh
case "$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  shell)
    case "$*" in
      *"content://com.android.contacts"*) printf 'Row: 0 display_name=A, data1=+1\n' ;;
      *"content://sms"*)                  printf 'No result found.\n' ;;
      *"content://call_log"*)             printf 'Error while accessing provider:call_log\njava.lang.SecurityException: Permission Denial\n' ;;
      *"list-sessions"*)                  printf 'Sessions:\n  tag=x, package=com.example.player\n' ;;
      *"query-activities"*)               printf '      packageName=com.example.player\n      packageName=com.example.radio\n' ;;
      *"enabled_notification_listeners"*) printf 'com.termux.api/com.termux.api.apis.NotificationListAPI\n' ;;
      *"ro.build.version.release"*)       printf '16\n' ;;
      *"ro.build.version.sdk"*)           printf '36\n' ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
CEOF
chmod +x "$CT/adb"
out="$(PATH="$CT:$PATH" TMPDIR="$CT" PHONE_LEDGER="$CT/l.jsonl" \
       "$PHONE" capabilities --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["capabilities"]
assert c["contacts"]["ok"] is True, c["contacts"]
# An empty table is READABLE, not denied — the distinction that took a
# permission dump to settle by hand.
assert c["sms"]["ok"] is True, c["sms"]
assert "empty" in c["sms"]["detail"].lower(), c["sms"]
# A real SecurityException IS denial, and must read differently.
assert c["call_log"]["ok"] is False, c["call_log"]
assert "deni" in c["call_log"]["detail"].lower(), c["call_log"]
assert c["media_session"]["ok"] is True, c["media_session"]
assert "com.example.player" in c["play_from_search"]["detail"], c
assert d["android"]["release"] == "16", d["android"]
' 2>/dev/null; then
  ok "capabilities reports yes / no / empty-but-readable distinctly"
else bad "capabilities probe (got: $out)"; fi

# With no device at all, every answer must be "could not check" — never "no".
out="$(TMPDIR="$CT" PHONE_NO_DEVICE=1 PHONE_LEDGER="$CT/l2.jsonl" \
       "$PHONE" capabilities --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
# Everything that depends on the DEVICE must be unknown. termux_api is
# excluded deliberately: with no device in play that is a true statement
# about this machine, not a guess about a phone. Addressed WITH --device,
# capabilities runs ON the phone instead, precisely so that answer is
# about the phone rather than about whoever is asking.
dev = {k: v["ok"] for k, v in d["capabilities"].items() if k != "termux_api"}
assert all(v is None for v in dev.values()), dev
' 2>/dev/null; then
  ok "no device means unknown, never a confident no"
else bad "unknown vs no (got: $out)"; fi

out="$(PATH="$CT:$PATH" TMPDIR="$CT" PHONE_LEDGER="$CT/l3.jsonl" \
       "$PHONE" capabilities 2>&1)"
if printf '%s' "$out" | grep -qi "contacts" && printf '%s' "$out" | grep -qi "call_log"; then
  ok "capabilities prints a table a human can read"
else bad "capabilities human output (got: $out)"; fi
rm -rf "$CT"

echo "== play should ASK the app, not hunt its UI for a coordinate"
# Playing a song by searching the app, dumping the whole UI tree to read
# artist names, and tapping a row is the computer-use pattern. Android has a
# standard intent for exactly this -- MEDIA_PLAY_FROM_SEARCH -- and the
# device will say which apps implement it. Crucially they DIFFER, from app to
# app and from phone to phone. So the handler table has to be read off the
# device, never hardcoded, and the fallback has to be honest about being a
# fallback.
IT="$(mktemp -d)"
mkintentstub() {   # $1 = packages that handle MEDIA_PLAY_FROM_SEARCH
  cat > "$IT/adb" <<EOF
#!/bin/sh
case "\$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  shell)
    case "\$*" in
      *"query-activities"*)
        for p in $1; do
          printf '      name=%s.MainActivity\n      packageName=%s\n' "\$p" "\$p"
        done ;;
      *"pm list packages"*) printf 'package:com.google.android.apps.youtube.music\npackage:com.apple.android.music\n' ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$IT/adb"
}

mkintentstub "com.google.android.apps.youtube.music"
out="$(PATH="$IT:$PATH" TMPDIR="$IT" PHONE_LEDGER="$IT/l.jsonl" \
       "$PHONE" play "northern lights" --app ytmusic --dry-run 2>&1)"
if printf '%s' "$out" | grep -q "MEDIA_PLAY_FROM_SEARCH" \
   && printf '%s' "$out" | grep -q "northern lights"; then
  ok "an app that declares the intent is asked directly (no UI)"
else bad "intent route not chosen (got: $out)"; fi

out="$(PATH="$IT:$PATH" TMPDIR="$IT" PHONE_LEDGER="$IT/l2.jsonl" \
       "$PHONE" play "northern lights" --app applemusic --dry-run 2>&1)"
# Assert on the TIER CHOSEN, not on the absence of the intent name -- the
# fallback message legitimately names the intent it could not use, so a check
# for that absence fails on correct output for saying so.
if printf '%s' "$out" | grep -q "tier=link" \
   && printf '%s' "$out" | grep -qi "does not declare" \
   && ! printf '%s' "$out" | grep -q "tier=intent"; then
  ok "an app that does NOT declare it says so, and says it is falling back"
else bad "fallback not announced (got: $out)"; fi

# The tier must be in the record. "played it (asked the app)" and "played it
# (tapped 540,1203)" are different claims about how much to trust the result.
PATH="$IT:$PATH" TMPDIR="$IT" PHONE_LEDGER="$IT/l3.jsonl" \
  "$PHONE" play "northern lights" --app ytmusic --dry-run >/dev/null 2>&1
if [ -s "$IT/l3.jsonl" ] && grep -q '"tier": "intent"' "$IT/l3.jsonl"; then
  ok "the trace records WHICH tier did the work"
else bad "tier not recorded (got: $(cat "$IT/l3.jsonl" 2>/dev/null))"; fi
rm -rf "$IT"

echo "== play must not report playing when it opened a web page"
# The third sibling of the wa.me shape. play hands a https URL to launch(),
# which opens a BROWSER when the app is absent and returns 0 -- and play
# recorded "act" BEFORE even attempting, so a launch that died outright still
# left a row asserting music was playing.
#
# The trap in fixing it: `apps` lists THIRD-PARTY packages only, and YouTube
# and YouTube Music are SYSTEM packages on a Pixel. Checking against that
# list would refuse ytmusic on a phone that has it -- swapping a false
# success for a false refusal, which is not an improvement.
PT="$(mktemp -d)"
mkplaystub() {   # $1 = packages `pm list packages <filter>` should report
  cat > "$PT/adb" <<EOF
#!/bin/sh
case "\$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  shell)
    case "\$*" in
      *"pm list packages -3"*) printf 'package:com.spotify.music\n' ;;
      *"pm list packages"*)
        for p in $1; do
          case "\$*" in *"\$p"*) printf 'package:%s\n' "\$p" ;; esac
        done ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$PT/adb"
}

# A phone with YouTube Music as a SYSTEM app and no Spotify.
mkplaystub "com.google.android.apps.youtube.music com.google.android.youtube"
out="$(PATH="$PT:$PATH" TMPDIR="$PT" PHONE_LEDGER="$PT/p1.jsonl" \
       "$PHONE" play "some song" --app spotify 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "not installed\|is not on"; then
  ok "play refuses when the music app is absent"
else bad "play opened a browser and called it playing (rc=$rc out=$out)"; fi
# Assert on the ABSENCE of a success row, not on a string that does not
# exist yet -- otherwise this passes today for no reason at all.
if [ ! -s "$PT/p1.jsonl" ] || python3 -c "
import json
rows=[json.loads(l) for l in open('$PT/p1.jsonl') if l.strip()]
ok=[r for r in rows if r.get('verb')=='play' and not r.get('rc')]
assert not ok, ok
" 2>/dev/null; then
  ok "and no successful play was claimed in the ledger"
else bad "ledger claims music that never played"; fi

# The false-refusal guard: ytmusic is a system package, absent from `apps`.
out="$(PATH="$PT:$PATH" TMPDIR="$PT" PHONE_LEDGER="$PT/p2.jsonl" \
       "$PHONE" play "some song" --app ytmusic 2>&1)"; rc=$?
# The claim under test is "not mistaken for MISSING", so assert on the
# failure mode first: under a stub nothing can actually play, so "opened it,
# nothing started" is the honest outcome and must not be read as a
# regression. Only "not installed" would be the bug.
if ! printf '%s' "$out" | grep -qi "not installed"; then
  ok "a SYSTEM music app is not mistaken for a missing one"
else bad "system app wrongly refused (rc=$rc out=$out)"; fi
# ...and that honest outcome exits 4: watched, and it did not happen. It used
# to be 5, which means refused, and a caller would wait for a lease that
# nobody holds.
if [ $rc -eq 4 ] && printf '%s' "$out" | grep -q "nothing is playing"; then
  ok "opened, but nothing playing, is a failure (exit 4), not a refusal"
else bad "play with nothing playing (rc=$rc out=$out)"; fi

# A launch that fails outright must leave a FAILURE row, not silence and not
# the success row play used to write before it had any evidence.
out="$(TMPDIR="$PT" PHONE_NO_DEVICE=1 PHONE_LEDGER="$PT/p3.jsonl" \
       "$PHONE" play "some song" --app ytmusic 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ -s "$PT/p3.jsonl" ] && \
   python3 -c "
import json,sys
rows=[json.loads(l) for l in open('$PT/p3.jsonl') if l.strip()]
a=rows[-1]
assert a['verb']=='play', a
assert a.get('rc'), a
assert 'fail' in str(a.get('result','')).lower(), a
" 2>/dev/null; then
  ok "a failed launch is recorded as a failure, not as playing"
else bad "failed launch record (rc=$rc ledger=$(cat "$PT/p3.jsonl" 2>/dev/null))"; fi
rm -rf "$PT"

echo "== msg must not report a draft on a phone without the app"
# cmd_open already learned this: "asking for whatsapp and getting a browser
# open on wa.me is not what anyone means". msg never did. It hands
# https://wa.me/<n> straight to launch(), which opens a BROWSER when
# WhatsApp is absent, returns 0, and records "drafted" -- so the agent tells
# the human a message is waiting to be tapped, and there is no message. In
# the one verb where the whole point is that it can really send.
AT="$(mktemp -d)"
mkstub() {   # $1 = package list emitted by `pm list packages -3`
  cat > "$AT/adb" <<EOF
#!/bin/sh
case "\$1" in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
  shell)   case "\$*" in
             *"pm list packages"*) printf '$1' ;;
             *) exit 0 ;;
           esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$AT/adb"
}

mkstub 'package:com.example.notes\npackage:com.example.player\n'
out="$(PATH="$AT:$PATH" TMPDIR="$AT" PHONE_LEDGER="$AT/led.jsonl" \
       "$PHONE" msg whatsapp --to "+15555550142" --text "hi" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "not installed\|no whatsapp\|is not on"; then
  ok "msg refuses honestly when WhatsApp is not on the device"
else bad "msg drafted into thin air (rc=$rc out=$out)"; fi
if [ ! -s "$AT/led.jsonl" ] || ! grep -q '"drafted"' "$AT/led.jsonl"; then
  ok "and no draft was claimed in the ledger"
else bad "ledger claims a draft that cannot exist"; fi
# --send is the dangerous half: it must refuse on the same evidence, and
# BEFORE anything is launched, not discover it at the send button.
out="$(PATH="$AT:$PATH" TMPDIR="$AT" PHONE_LEDGER="$AT/led3.jsonl" \
       "$PHONE" msg whatsapp --to "+15555550142" --text "hi" --send 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "not installed"; then
  ok "--send refuses on the same evidence"
else bad "--send proceeded without the app (rc=$rc out=$out)"; fi

mkstub 'package:com.whatsapp\npackage:com.example.notes\n'
out="$(PATH="$AT:$PATH" TMPDIR="$AT" PHONE_LEDGER="$AT/led2.jsonl" \
       "$PHONE" msg whatsapp --to "+15555550142" --text "hi" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && grep -q '"drafted"' "$AT/led2.jsonl" 2>/dev/null; then
  ok "with WhatsApp installed it still drafts, and says so"
else bad "installed-app draft path broke (rc=$rc out=$out)"; fi
# msg has the same die-before-record gap play had: launch() dies loudly when
# it cannot open anything, and the record was written only after it returned.
# A message the agent tried and failed to draft left no trace at all, which
# reads as never having been asked.
out="$(TMPDIR="$AT" PHONE_NO_DEVICE=1 PHONE_LEDGER="$AT/led4.jsonl" \
       "$PHONE" msg whatsapp --to "+15555550142" --text "hi" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ -s "$AT/led4.jsonl" ] && python3 -c "
import json
rows=[json.loads(l) for l in open('$AT/led4.jsonl') if l.strip()]
a=rows[-1]
assert a['verb']=='msg', a
assert a.get('rc'), a
assert 'fail' in str(a.get('result','')).lower(), a
" 2>/dev/null; then
  ok "a draft that could not be opened is recorded as a failure"
else bad "msg failed launch record (rc=$rc led=$(cat "$AT/led4.jsonl" 2>/dev/null))"; fi
rm -rf "$AT"

echo "== a remote hop is the LAST hop"
# If the device's own environment names a device (a two-phone setup, a
# stray export), the far `phone` would hop onward -- and every row it
# returned would still be labelled with THIS device's name, because that is
# the only name the caller knows. The origin column would then quietly
# attribute a third machine's actions to the phone in your hand, which is
# worse than not having the column. Cheaper to make the far side incapable
# of hopping than to teach the labelling about hops it cannot see.
HT="$(mktemp -d)"
cat > "$HT/phone" <<'HEOF'
#!/bin/sh
printf 'DEVICE=[%s]\n' "$PHONE_DEVICE"
HEOF
chmod +x "$HT/phone"
plan="$(PHONE_ACTOR=alice "$PHONE" --device test-phone --print-plan notifs 2>&1)"
remote="${plan#*test-phone }"
got="$(PATH="$HT:$PATH" PHONE_DEVICE=some-other-phone sh -c "$remote" 2>&1)"
rm -rf "$HT"
if [ "$got" = "DEVICE=[]" ]; then
  ok "the far side cannot hop onward (PHONE_DEVICE cleared across the wire)"
else bad "far side could re-hop (got: $got)"; fi

echo "== the hop lands where the caller aimed it, whatever the phone's file says"
# The phone's copy of `phone` reads the phone's config file. A PHONE_LANE,
# PHONE_SHELL_SOCK or PHONE_DISPLAY set there must not retarget a
# controller's verb: the lease would be checked against some other daemon,
# so a held display stops refusing anyone, or a display-0 verb would act on
# another screen. Run end to end with the real CLI as the far side: a daemon
# on the phone's default socket, a lease bob holds on display 0, and alice's
# hopped `torch on`, which must be refused (exit 5) however the file is set.
plan="$("$PHONE" --device test-phone --print-plan notifs 2>&1)"
case "$plan" in
  *"PHONE_LANE= PHONE_SHELL_SOCK= PHONE_DISPLAY= PHONE_DEVICE= phone notifs")
    ok "the remote command clears the lane, the socket and the display" ;;
  *) bad "hop pins (got: $plan)" ;;
esac
HP="$T/hop"; mkdir -p "$HP/bin"
ln -s "$PHONE" "$HP/bin/phone"
HSOCK="$PREFIX/tmp/phone-shell.sock"
PHONE_SHELL_SOCK="$HSOCK" PHONE_SHELL_ARGV=sh "$PHONE" shelld --start >/dev/null 2>&1
PHONE_SHELL_SOCK="$HSOCK" PHONE_ACTOR=bob PHONE_LEDGER="$HP/l.jsonl" \
  "$PHONE" lease acquire --ttl 600 >/dev/null 2>&1
plan="$(PHONE_ACTOR=alice "$PHONE" --device test-phone --print-plan torch on 2>&1)"
remote="${plan#*test-phone }"
for cfg in "PHONE_LANE=elsewhere" "PHONE_DISPLAY=5" "PHONE_SHELL_SOCK=$HP/other.sock"; do
  printf '%s\n' "$cfg" > "$HP/config"
  out="$(PATH="$HP/bin:$PATH" PHONE_CONFIG="$HP/config" PHONE_LEDGER="$HP/l.jsonl" \
         sh -c "$remote" 2>&1)"; rc=$?
  if [ $rc -eq 5 ] && printf '%s' "$out" | grep -q "bob"; then
    ok "a phone-side ${cfg%%=*} does not take the hop past bob's lease"
  else bad "a phone-side $cfg retargeted the hop (rc=$rc out=$out)"; fi
done
PHONE_SHELL_SOCK="$HSOCK" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== a lane's daemon starts on the phone, whatever the phone's file names"
# Starting a lane's daemon is a hop like any other. Without PHONE_DEVICE= in
# front of it, a phone whose config file named a device started no lane
# daemon at all, and made three ssh attempts of its own toward that device.
# Run the exact command a controller sends, with the real CLI as the far side.
LF="$T/lane-far"; mkdir -p "$LF/bin" "$LF/prefix"
ln -s "$PHONE" "$LF/bin/phone"
printf '#!/bin/sh\necho "ssh $*" >> "%s/ssh.log"\nexit 255\n' "$LF" > "$LF/bin/ssh"
chmod +x "$LF/bin/ssh"
printf 'PHONE_DEVICE=other-phone\n' > "$LF/phone-config"
start="$(PHONE_PATH="$PHONE" PHONE_LANE=alpha TMPDIR="$LF" python3 - 2>/dev/null <<PY
$PRELUDE
calls = []
def fake_run(argv, timeout=30, want_bytes=False):
    calls.append(argv)
    return 0, ""
m.run = fake_run
m.shelld_call = lambda *a, **k: None      # no daemon ever answers
m.time.sleep = lambda s: None
try:
    m.ensure_link("test-phone")
except SystemExit:
    pass
starts = [c[-1] for c in calls if c and c[0] == "ssh" and "shelld --start" in c[-1]]
print(starts[0] if starts else "none")
PY
)"
PATH="$LF/bin:$PATH" PREFIX="$LF/prefix" PHONE_CONFIG="$LF/phone-config" \
  PHONE_SHELL_ARGV=sh sh -c "$start" >/dev/null 2>&1; rc=$?
if [ $rc -eq 0 ] && [ -S "$LF/prefix/tmp/phone-shell-alpha.sock" ] && [ ! -e "$LF/ssh.log" ]; then
  ok "the far side starts the lane's daemon itself, and hops nowhere"
else bad "lane start on the far side (rc=$rc start=$start ssh: $(cat "$LF/ssh.log" 2>/dev/null))"; fi
PHONE_SHELL_SOCK="$LF/prefix/tmp/phone-shell-alpha.sock" "$PHONE" shelld --stop >/dev/null 2>&1

echo "== the trace is split across two machines, so log has to merge it"
# Shell-tier verbs (tap, type, look, key) execute through the forwarded
# socket, so the CONTROLLER's process writes their ledger line -- on the
# controller. Termux verbs run on the device, so the DEVICE writes theirs.
# Two ledgers, on two machines, each holding half the story: `phone log`
# here showed taps with no reads, `phone log` there showed reads with no
# taps, and neither could answer "what has been done to my phone, by whom".
MT="$(mktemp -d)"
cat > "$MT/ledger.jsonl" <<'LEOF'
{"ts": 100.0, "verb": "tap", "kind": "act", "actor": "alice", "ms": 12, "rc": 0, "detail": "933 2119"}
{"ts": 300.0, "verb": "type", "kind": "act", "actor": "alice", "ms": 20, "rc": 0, "detail": "hello"}
LEOF
# A stub ssh standing in for the device's own ledger.
cat > "$MT/ssh" <<'SEOF'
#!/bin/sh
echo '[{"ts": 200.0, "verb": "notifs", "kind": "read", "actor": "alice", "ms": 9, "rc": 0, "detail": "all"}]'
SEOF
chmod +x "$MT/ssh"
# TMPDIR too, so no forwarded socket left over from a real run can be
# found and make this pass for a reason the test did not arrange.
out="$(PATH="$MT:$PATH" TMPDIR="$MT" PHONE_LEDGER="$MT/ledger.jsonl" \
       "$PHONE" --device test-phone log --json 2>&1)"
if printf '%s' "$out" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
verbs = [r["verb"] for r in rows]
assert verbs == ["type", "notifs", "tap"], verbs      # newest first, interleaved
o = {r["verb"]: r.get("origin") for r in rows}
assert o["notifs"] == "test-phone", o
assert o["tap"] == "here" and o["type"] == "here", o
' 2>/dev/null; then
  ok "log merges both ledgers in time order, each row saying where it came from"
else bad "split ledger not merged (got: $out)"; fi

# The device being unreachable must not make the local half vanish -- a
# partial answer is worth having, an empty one that looks complete is not.
cat > "$MT/ssh" <<'SEOF'
#!/bin/sh
echo "ssh: connect to host test-phone port 8022: Host is down" >&2
exit 255
SEOF
chmod +x "$MT/ssh"
out="$(PATH="$MT:$PATH" TMPDIR="$MT" PHONE_LEDGER="$MT/ledger.jsonl" \
       "$PHONE" --device test-phone log 2>&1)"
rc=$?
if printf '%s' "$out" | grep -q "tap" && printf '%s' "$out" | grep -qi "could not read\|unreachable"; then
  ok "an unreachable device still shows local rows, and says the half is missing"
else bad "unreachable device handling (got: $out)"; fi
# ...and it must not exit 0. A caller asking what was done to the phone would
# read success as "and that was all of it".
if [ "$rc" -ne 0 ]; then
  ok "a half-trace exits non-zero"
else bad "partial trace exited 0 (looked complete)"; fi

echo "== the config file: PHONE_* settings for shells that never read a profile"
# KEY=VALUE lines, `#` comments and blank lines ignored, an `export ` prefix
# allowed, one layer of matching quotes stripped. Only PHONE_ keys count; the
# environment always wins; a missing file is silent; anything wrong is ONE
# warning on stderr and never an exit.
CF="$T/cfg"; mkdir -p "$CF"
cat > "$CF/full" <<'EOF'
# a comment, then a blank line

PHONE_ACTOR=plain
export PHONE_LANE="double quoted"
PHONE_DISPLAY='single quoted'
PHONE_REMOTE_BIN="mismatched'
   PHONE_ROUTER=indented line
EDITOR=a-secret-looking-value
this line is not an assignment
PHONE_SPACED = is not an assignment either
PHONE_CONFIG=/somewhere/else
PHONE_ACTOR=last one wins
EOF
out="$(PHONE_PATH="$PHONE" python3 - "$CF/full" <<PY
$PRELUDE
settings, problems = m.parse_config(open(sys.argv[1]).read())
want = {"PHONE_ACTOR": "last one wins", "PHONE_LANE": "double quoted",
        "PHONE_DISPLAY": "single quoted", "PHONE_REMOTE_BIN": "\"mismatched'",
        "PHONE_ROUTER": "indented line"}
assert settings == want, settings
assert len(problems) == 4, problems
assert any("EDITOR" in p for p in problems), problems
# The file cannot redirect itself: only the environment chooses PHONE_CONFIG.
# (No apostrophes in this here-document: bash 3.2 matches quotes inside a
# here-document nested in a command substitution, so one stray apostrophe
# here is a syntax error for the whole suite under macOS /bin/bash.)
assert any("PHONE_CONFIG" in p for p in problems), problems
# Reported by name, never by value: a value is what might be a secret.
assert not any("secret" in p for p in problems), problems
print("ok")
PY
)"
if [ "$out" = "ok" ]; then
  ok "comments, blank lines, export and one layer of matching quotes are handled"
else bad "config parsing (got: $out)"; fi

printf 'PHONE_ACTOR=from-config\n' > "$CF/actor"
actor_of(){   # the actor recorded by one read, under whatever env is given
  rm -f "$CF/l.jsonl"
  env "$@" PHONE_LEDGER="$CF/l.jsonl" "$PHONE" notifs --from "$T/notifs.json" >/dev/null 2>"$CF/err"
  python3 -c "
import json
rows=[json.loads(l) for l in open('$CF/l.jsonl') if l.strip()]
print(rows[-1]['actor'])" 2>/dev/null
}
got="$(actor_of PHONE_CONFIG="$CF/actor")"
if [ "$got" = "from-config" ]; then ok "a setting in the file reaches the CLI"
else bad "config value not applied (actor=$got)"; fi
got="$(actor_of PHONE_CONFIG="$CF/actor" PHONE_ACTOR=from-env)"
if [ "$got" = "from-env" ]; then ok "the environment wins over the file"
else bad "file beat the environment (actor=$got)"; fi
got="$(actor_of PHONE_CONFIG="$CF/actor" PHONE_ACTOR=)"
if [ "$got" = "anon" ]; then ok "an EMPTY value in the environment still wins"
else bad "an empty env value was filled from the file (actor=$got)"; fi
mkdir -p "$CF/xdg/parallel-root"
printf 'export PHONE_ACTOR="from-xdg"\n' > "$CF/xdg/parallel-root/config"
got="$(actor_of -u PHONE_CONFIG XDG_CONFIG_HOME="$CF/xdg")"
if [ "$got" = "from-xdg" ]; then
  ok "without PHONE_CONFIG the file is \$XDG_CONFIG_HOME/parallel-root/config"
else bad "default config path (actor=$got)"; fi
got="$(actor_of PHONE_CONFIG=/dev/null)"
if [ "$got" = "anon" ] && [ ! -s "$CF/err" ]; then ok "PHONE_CONFIG=/dev/null reads nothing"
else bad "/dev/null config (actor=$got err=$(cat "$CF/err"))"; fi

# The far side of a hop runs with PHONE_DEVICE= precisely so it cannot hop
# onward. A config file there naming a device must not undo that.
printf 'PHONE_DEVICE=test-phone\n' > "$CF/device"
cat > "$CF/l2.jsonl" <<'LEOF'
{"ts": 100.0, "verb": "tap", "kind": "act", "actor": "alice", "ms": 12, "rc": 0, "detail": "1 2"}
LEOF
out="$(PHONE_DEVICE= PHONE_CONFIG="$CF/device" PHONE_LEDGER="$CF/l2.jsonl" "$PHONE" log --json 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows and all("origin" not in r for r in rows), rows
' 2>/dev/null; then
  ok "an empty PHONE_DEVICE beats a config file's device (the last hop stays last)"
else bad "config re-armed a cleared device (rc=$rc out=$out)"; fi

# Loaded BEFORE the global flags: the file's device is the default, and
# --device still beats it.
out="$(PHONE_CONFIG="$CF/device" "$PHONE" --print-link 2>&1)"
if printf '%s' "$out" | grep -q " test-phone$"; then ok "a device named in the file is used like an exported one"
else bad "config device not used by the global flags (got: $out)"; fi
out="$(PHONE_CONFIG="$CF/device" "$PHONE" --device other-phone --print-link 2>&1)"
if printf '%s' "$out" | grep -q " other-phone$" && ! printf '%s' "$out" | grep -q "test-phone"; then
  ok "and --device on the command line still beats it"
else bad "--device lost to the config file (got: $out)"; fi

printf 'EDITOR=vim\nPATH=/nowhere\nnot an assignment\nPHONE_ACTOR=cfg\n' > "$CF/mixed"
got="$(actor_of PHONE_CONFIG="$CF/mixed")"
warns="$(grep -c "warning" "$CF/err")"
if [ "$got" = "cfg" ] && [ "$warns" = "1" ] && grep -q "EDITOR" "$CF/err" \
   && grep -q "PATH" "$CF/err" && ! grep -q "/nowhere" "$CF/err"; then
  ok "non-PHONE keys are ignored with ONE warning, naming keys, never values"
else bad "non-PHONE keys (actor=$got warnings=$warns err=$(cat "$CF/err"))"; fi
out="$(PHONE_PATH="$PHONE" PHONE_CONFIG="$CF/mixed" python3 - <<PY 2>/dev/null
$PRELUDE
os.environ.pop("EDITOR", None)
path_before = os.environ.get("PATH")
m.load_config()
print("ok" if "EDITOR" not in os.environ and os.environ.get("PATH") == path_before
      else "leaked")
PY
)"
if [ "$out" = "ok" ]; then ok "and they never reach the environment"
else bad "a non-PHONE key was exported (got: $out)"; fi

got="$(actor_of PHONE_CONFIG="$CF/not-there")"
if [ "$got" = "anon" ] && [ ! -s "$CF/err" ]; then ok "a missing config file is silent"
else bad "missing config (actor=$got err=$(cat "$CF/err"))"; fi
got="$(actor_of PHONE_CONFIG="$CF")"
if [ "$got" = "anon" ] && grep -q "warning" "$CF/err" && [ "$(grep -c . "$CF/err")" = "1" ]; then
  ok "an unreadable config file is one warning, never an exit"
else bad "unreadable config (actor=$got err=$(cat "$CF/err"))"; fi

# The daemon's timings are read by EVERY verb, so a value that is not a
# number of seconds must cost a warning, not the CLI: it used to be a
# traceback from every verb, and a config file makes that one typo away.
printf 'PHONE_SHELLD_IDLE=an-hour\n' > "$CF/timing"
got="$(actor_of PHONE_CONFIG="$CF/timing")"
if [ "$got" = "anon" ] && [ "$(grep -c . "$CF/err")" = "1" ] \
   && grep -q "PHONE_SHELLD_IDLE" "$CF/err" && ! grep -q "Traceback" "$CF/err"; then
  ok "a timing in the file that is not a number is one warning, and the verb runs"
else bad "bad timing in the file (actor=$got err=$(cat "$CF/err"))"; fi
got="$(actor_of PHONE_SHELL_DEADLINE=-5)"
if [ "$got" = "anon" ] && grep -q "PHONE_SHELL_DEADLINE" "$CF/err" \
   && ! grep -q "Traceback" "$CF/err"; then
  ok "and an exported one is treated the same way"
else bad "bad exported timing (actor=$got err=$(cat "$CF/err"))"; fi
out="$(PHONE_PATH="$PHONE" PHONE_SHELLD_TICK=0 PHONE_SHELLD_IDLE=0 python3 - 2>/dev/null <<PY
$PRELUDE
print("%g %g %g" % (m._SHELLD_DEADLINE, m._SHELLD_TICK, m._SHELLD_IDLE))
PY
)"
if [ "$out" = "75 30 0" ]; then
  ok "IDLE=0 still means never exit; a zero tick falls back to the default"
else bad "timing defaults (got: $out)"; fi
out="$(PHONE_PATH="$PHONE" PHONE_SHELLD_IDLE=-1 python3 - 2>"$CF/err" <<PY
$PRELUDE
print("%g" % m._SHELLD_IDLE)
PY
)"
if [ "$out" = "0" ] && [ ! -s "$CF/err" ]; then
  ok "a negative IDLE means never exit too, and is not warned about"
else bad "negative IDLE (got: $out err=$(cat "$CF/err"))"; fi
rm -rf "$MT"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
