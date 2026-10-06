# Displays

This page covers how several agents share one phone: why each agent gets a
second screen instead of waiting its turn on the first, how such a screen is
made without root, and what a second screen still does not give you. Every
measurement here is from the reference device (Pixel 10, Android 16, SDK 36).

## Why a second screen

A lease makes agents take turns on one screen. That is safe, but it is
slow, and a long task on the person's phone takes the phone away from the
person while it runs. A longer lease does not help with either.

A virtual display does. It is not a bigger screen. It is a separate one,
with its own resumed activity, its own focus and its own input stream.
Measured: the launcher was resumed on display 0, Chrome on display 6 and a
calendar on display 7, all at once, and the built-in screen never changed.
`dumpsys activity activities` prints a `Display #N` section for each
display, each with its own top resumed activity.

## Trusted virtual displays, at shell uid

A virtual display is only worth having if it is **trusted**. An untrusted
display gets no input method, no focus of its own and no system decorations.
The display manager removes those flags without reporting an error.

A trusted display needs `ADD_TRUSTED_DISPLAY`. That is a `signature|role`
permission, which an app cannot be granted; `pm grant` refuses it as "not a
changeable permission type". But `com.android.shell` holds it (AOSP
`packages/Shell/AndroidManifest.xml`, since Android 13), and `phone sh`
already runs at uid 2000 through Shizuku. So the display is created by code
running as shell:

```
CLASSPATH=/data/local/tmp/parallel-root-vdisplay.jar \
  setsid app_process / parallelroot.vdisplay.Main \
  --size 1080x2424 --dpi 420 --name pr-vd-1 --socket pr-vd-1
```

Nothing is bypassed. The code runs as the uid that already has the
permission. scrcpy's `--new-display` works the same way.

Two details that make it work:

- **The holder needs its own context.** `getSystemService()` on a wrapped
  context hands back a display manager bound to the system context, whose
  package is `android`, owned by uid 1000. Called from uid 2000 it fails
  with `SecurityException: packageName must match the calling uid`. That
  reads like a permission problem but is a naming one. The holder builds its
  display manager against a context that reports `com.android.shell`.
- **The display must outlive the command.** A virtual display belongs to the
  process that created it and is released when that process exits. So the
  holder is not a one-shot command. It creates the display, prints `display
  <id>`, and idles until told to stop. `phone display create` starts it with
  `setsid`, because the shell daemon kills its shell's whole process group
  when a command overruns its deadline. A holder in that group would vanish
  the next time an unrelated command timed out.

The holder sets `DESTROY_CONTENT_ON_REMOVAL`, so releasing a display takes
its apps with it. Without that flag, apps on a released display move to the
person's screen. That was observed: after two holders were killed, Settings
appeared in front of the launcher with nothing to explain it.

## The holder protocol

Each holder listens on an abstract-namespace local socket named after its
display (`pr-vd-1`, `pr-vd-2`, ...). Requests and replies are one line each:

| request | reply |
|---|---|
| `info` | `<id> <w>x<h>/<dpi>` |
| `cap <path>` | `ok <path>` once a PNG of the latest frame has been written to `<path>` |
| `bye` | `ok`; then the holder exits and the display is released |

The Termux app cannot connect to that socket. It is owned by shell, and
SELinux refuses the connection (measured: `EACCES`). So `phone` talks to it
through a second class in the same jar, `parallelroot.vdisplay.Client`,
started with `app_process` at shell uid through the shell tier.

There is no registry file. `phone display ls` asks the phone (`cmd display
get-displays`), and a display counts as ours when its name starts with
`pr-vd-`. Which displays exist is a fact about the device, and a file that
disagrees with the device would be wrong.

## Capture goes through the holder

`screencap -d <id>` cannot capture a virtual display. `screencap` addresses
SurfaceFlinger's physical display ids, which are a different set of numbers
from the ids that `am start --display` and `input -d` use. A virtual
display has no physical id, so the flag silently returns the built-in screen
or nothing.

The only process that can read a virtual display's pixels is the one that
owns its surface. The holder renders into an `ImageReader`, keeps the newest
frame, and writes it out as a PNG when asked with `cap`. It has to keep a
frame because a virtual display renders only when its content changes: a
holder that closed every image as it arrived would answer "no frame
available yet" forever on any screen that had stopped changing. The reader
also has to be drained whether or not anyone wants a picture: an
`ImageReader` whose images are never taken stops the producer, and the
display would freeze.

`phone --display N screen --out f.png` asks the holder to write the PNG to
`/sdcard`, which the shell uid can write and the Termux app can read, then
reads it (over ssh from a controller), checks the PNG signature, and
deletes the file on the phone.

| tool | display flag | works on a virtual display? |
|---|---|---|
| `am start` | `--display N` | yes; shell holds `INTERNAL_SYSTEM_WINDOW`, which skips the trust check |
| `input` | `-d N` | yes. Use `-d`; `input` rejects `--display`. |
| `wm size` | `-d N` | yes |
| `uiautomator dump` | `--windows` | yes, with two traps (below) |
| `screencap` | `-d N` | no; capture through the holder |

### Reading the tree of one display

`uiautomator dump --windows` returns every window on every display. It has
two traps:

1. **Windows are listed top first.** The status bar (layer 1) comes before
   the app window (layer 0). Inside a view hierarchy, a later sibling is
   drawn on top, and the tap resolver's occlusion check depends on that.
   Merging windows in document order tells it the status bar is underneath
   the app. `phone` merges them bottom first, by layer.
2. **It returns every display, and large reads corrupt.** With two extra
   displays the dump was 121 KB, and the checked read failed four attempts
   in a row. `phone` cuts out the one display it needs on the device, with
   `sed`, before reading anything back. The read then stays the same size
   however many other displays exist.

### Which app is in front

`dumpsys activity activities | grep -m1 ResumedActivity` returned the right
answer while there was one display. dumpsys prints virtual displays before
the built-in one, so with a second display, the first match belongs to some
other screen. Measured: with a clock on display 5, `phone foreground`
reported the clock while the person was looking at their launcher. `msg`
checks this before sending. Every foreground check now reads only the
`Display #N` section it was asked about, including display 0.

## One app, one display

A display multiplies screens. It does not multiply apps. Behind an app there
is one process, one signed-in account and one notification stream, however
many displays show it.

`am start --display N` on an app that already has a task somewhere else does
not start a second copy. It **moves the task**. The agent driving that app
on the old display loses it mid-turn, and nothing reports an error. So
`phone open` refuses, with exit 5, to open an app that is already on another
display:

```
phone: com.example.notes is already open on display 6 — one app, one display. ...
```

To move an app on purpose:

```sh
phone display move notes --to 7        # com.example.notes: display 6 -> 7
phone display move notes --to 0        # hand it to the person's screen
```

This is the same `am start --display` that `open` refuses to do implicitly.
Here it is allowed because a move is what was asked for. Android has no way
to copy a task, so it always leaves the old display. A move takes the app
away from whoever drives the display it leaves and puts it in front of
whoever holds the one it goes to, so `move` refuses (exit 5) when another
agent holds the lease on either. Some apps refuse secondary displays
outright, so `move` checks where the app ended up and exits 4 if it did not
arrive. `PHONE_NO_DISPLAY_GUARD=1` disables the refusal in `open` for anyone
who needs to.

## Visible displays

`phone display create --visible` makes a display the person can see. It is
not a virtual display but an **overlay display**, which Android draws as a
floating window on the built-in screen. It is set through
`settings put global overlay_display_devices`. In that setting `;`
separates displays and `,` separates one display's flags.

It is a real display: it has its own launcher and its own resumed activity,
and `look` and `tap` reach it. Taps use the display's own coordinates, not
the position of its window. Measured: four taps on a calculator there
produced `7789` in the formula field. It has no framebuffer of its own,
though. Android composites it onto the built-in screen, so `--display N
screen` cannot capture it separately. Capture the built-in screen instead,
where it appears as a window.

| | `display create` | `display create --visible` |
|---|---|---|
| the person sees it | no | yes, as a floating window |
| `look`, `find`, `tap` | yes | yes |
| `screen` of that display alone | yes | no; capture the built-in screen |
| what keeps it alive | a holder process | an entry in a global setting |

Use the invisible kind by default, since the point is to work without taking
the phone from the person. Use the visible kind to show them what an agent
is doing. `display rm --all` removes overlay displays too. It leaves any
display another agent holds a lease on and names the holder. Every overlay
display is an entry in one setting, and Android answers any change to it by
dismissing all of them and creating the ones still listed afresh (AOSP's
`OverlayDisplayAdapter`), so while another agent holds one overlay, `rm
--all` leaves every overlay in place, and `rm` of any other overlay and
`create --visible` are refused.

## FLAG_SECURE

Windows that set `FLAG_SECURE` (banking apps, DRM video, some password
screens) render **black** on every display except the built-in one.
SurfaceFlinger lets only the graphics and system uids create secure
displays. Shell is not one of them, and root would not change that. A black
capture from a virtual display usually means this. Agents should report the
screen as unreadable, not as empty.

## Sleep

An agent's display sleeps when the phone does. The holder asks for a display
group of its own (`VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP`), but on the
reference device (Android 17) the display lands in display group 0 — the
person's — and `dumpsys power` lists one power group. So it shares the
person's power state:

- while the phone is awake, everything on this page works as described;
- while it dozes, an app on an agent's display is still resumed (`open` and
  `foreground` work) and draws nothing: the holder has no frame for `screen`,
  and `uiautomator` has no window for `look`. Both say "the phone is asleep"
  rather than blaming the display;
- waking only the agent's display is not possible: a wake key sent to it
  wakes the phone, and with it the person's screen.

So `phone` never wakes the phone on its own. When agents need pixels while
nobody is using the phone, plug it in and keep it awake while it charges —
`phone sh 'svc power stayon true'`, then `svc power stayon false` — or turn on
"Stay awake" in developer options. Both hold only while the phone is plugged
in. That is the person's call.

## What stays singular

However many displays exist, there is still one of each of these:

- **the apps**: one process and one account per package (see above);
- **the microphone and the speaker**: `say` and `listen` take turns, and
  there is only one conversation by voice;
- **the notification shade**: `notify` posts to the person's phone, and
  notifications from every display go to the same shade;
- **the person**: the one who sees display 0, receives every message an
  agent sends, and whom the skills require an agent to ask before sending
  anything.

## A worked example: two agents

Agent A organises notes, and agent B checks a delivery in a browser. Both
are on one controller, and the phone is `my-phone`.

```sh
# both
export PHONE_DEVICE=my-phone

# agent A
export PHONE_ACTOR=agent-a PHONE_LANE=a
phone display ls                          # read the room first
a=$(phone display create)                 # e.g. 6
phone --display "$a" lease acquire --as agent-a
phone --display "$a" open notes
phone --display "$a" look

# agent B, at the same time
export PHONE_ACTOR=agent-b PHONE_LANE=b
b=$(phone display create)                 # e.g. 7
phone --display "$b" lease acquire --as agent-b
phone --display "$b" open chrome
phone --display "$b" find "Track order"
phone --display "$b" tap --label "Track order" --look
```

What happens:

- Each agent has its own lane, so A's tree dumps do not block B's taps.
- Each lane has its own lease table. A's lease on 6 and B's lease on 7 live
  in different daemons, and each display has its own driver, so they do not
  need to see each other. Two agents that want to arbitrate over the same
  display must use the same lane, normally the default one.
- If B tries `phone --display 7 open notes` while notes is open on 6, it
  gets exit 5 and the message names display 6.
- The person's screen, display 0, never changes.

When they finish:

```sh
# agent A
phone --display "$a" lease release --as agent-a
phone display rm "$a"                     # takes notes with it

# agent B
phone --display "$b" lease release --as agent-b
phone display rm "$b"
phone display ls                          # only display 0 is left
```

`phone --device my-phone log --actor agent-b` shows what B did, with its
timings.
