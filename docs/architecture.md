# Architecture

`phone` is one Python file that runs in two places: on the phone inside
Termux, and on a controller that reaches the phone over ssh. This document
covers what happens between a verb and the device, and why it is built that
way. The numbers come from measurements on the reference device (Pixel 10,
Android 16) and are there to explain the design. Other phones will have
different numbers.

## Three routes

An unrooted phone offers three ways to get something done. They differ in
cost and in whether they can check their own result.

| route | mechanism | cost | checks itself? |
|---|---|---|---|
| 1. state | `content query`, `cmd <service>`, `dumpsys`, `settings` | about 0.5 s, a few bytes | yes: structured in, structured out |
| 2. intent | `am start -a <ACTION>`, deep links: the app does the work | about 1.5 s | only if you look afterwards |
| 3. screen | `uiautomator dump`, `input tap`, `input text`, `screencap` | about 4 s, 20 to 40 times the output | no |

The skills teach agents to try the highest route that could work and go down
only when it fails. The verbs are grouped the same way:

- **state**: `notifs`, `media`, `cal`, `contacts`, `battery`, `foreground`,
  `apps`, `capabilities`, `where`, `clip`, `log`, `sh`
- **intent**: `open`, `play`, `msg`, `reply`
- **screen**: `ui`, `look`, `find`, `tap`, `type`, `key`, `scroll`,
  `swipe`, `scan`, `screen`, `photo`, `torch`

The screen route cannot check itself because `input tap` exits 0 whether or
not anything handled the tap, `am start` exits 0 when an app accepts an
intent and does nothing with it, and a denied `content query` prints its
exception on stderr and exits 0. So `phone` folds stderr in where a diagnosis
is wanted (`phone sh`), reports "could not check" separately from "no"
(`capabilities`), and verifies what it can (`open` checks that the app came
to the front, `type` checks that a field is focused).

A screen dump costs about 3.1 s, and that time is spent on the phone.
Shipping the 25 to 60 KB tree back costs about 0.5 s. Filtering on the device
therefore saves little. What saves time is taking fewer dumps, which is why
`tap --label`, `tap --look` and `scan` exist. `scan` runs the whole
scroll-and-look loop on the device and returns a tap point.

## Shell tiers

Everything that needs shell uid goes through one function, which tries three
tiers in order:

1. **The persistent shell daemon** (`phone shelld`). This is a `rish` shell
   started once and kept alive behind a unix socket at
   `$PREFIX/tmp/phone-shell.sock`. A command is a socket round trip, about
   2 ms of overhead.
2. **rish**, spawned per command. Every `rish` invocation spends about
   1.14 s starting `app_process` and loading its dex, and the command itself
   usually takes milliseconds. Paying that on every verb made agents slow,
   which is why the daemon exists.
3. **adb**, against the phone's own wireless debugging endpoint. This is a
   fallback for phones without Shizuku. Android tears adb down after a
   network change or a period of idle, and an app cannot turn it back on.

When no tier answers, a verb that needs the shell exits 3. Shizuku itself is
not tied to a network connection: it runs as a service reached over Binder,
so a phone moving between networks keeps its shell tier.

### The sentinel protocol

The daemon's protocol is minimal on purpose. The client writes one command
line. The daemon writes it to its shell, followed by an echo of a sentinel
(`__PHONE_EOC__`) carrying `$?`. It returns everything up to the sentinel,
plus the exit status. Nothing is parsed that the shell did not print.
Control messages begin with a NUL byte (`\0shelld stop`, `\0lease ...`),
which no shell command can begin with.

The daemon keeps one shell process, so the working directory and the
environment persist between commands. Each command has a deadline
(`PHONE_SHELL_DEADLINE`, 75 s). A command that overruns has its shell's
process group killed, and the next command starts a fresh shell. The daemon writes a pidfile
next to its socket, so `shelld --stop` can always end it; unlinking the
socket alone would leave the process alive with nothing able to reach it.
`--stop` signals that pid only while it is still a shelld, since a daemon
killed outright leaves its pidfile naming whatever process gets the number
next. Every `PHONE_SHELLD_TICK` seconds the daemon checks whether it
should still be running. It exits once its socket has been unlinked or bound
by another daemon, or once it has been idle for `PHONE_SHELLD_IDLE` seconds,
an hour by default.

`shelld --start` never binds a new daemon over a live one. The leases live
only in the daemon's memory, so replacing it would free every display it
holds, and a daemon that is busy with someone's long command is still live:
it completes a connect even while it cannot answer. So `--start` reuses a
daemon that answers, leaves alone one that is busy or whose shell is not
answering (the second exits 4), and starts a new one only when nothing is
serving the socket, reporting success once the new daemon answers. A daemon
that cannot start its shell at all (no `rish`) exits 3 and leaves no socket
or pidfile behind.

The daemon carries text only. Binary results (`screen`) never cross it.

### Large reads

Large reads through the persistent shell can come back corrupted: the byte
count is right and a region of the content is wrong, sometimes replaced with
output from an earlier command. On the reference device this was clean at
4 KB, corrupt half the time at 9 KB and corrupt every time at 61 KB. The
cause is not known. `phone sh --checked` and the internal readers that need
it write the output to a file on the device, send its md5 ahead of the data,
and retry on a mismatch. Retries usually succeed within one to five attempts.
If every attempt fails, the verb exits 5 instead of returning data it cannot
vouch for.

### Lanes

The daemon serves one command at a time, so every driver's commands wait
behind every other driver's. `PHONE_LANE=<name>` selects a separate daemon
on its own socket (`phone-shell-<name>.sock`). Two four-second commands took
8.6 s through the shared daemon and 4.3 s in two lanes. The default lane is
unchanged and shared. When a controller asks for a lane whose daemon is not
running, `phone` starts it on the phone over ssh. The default lane is never
started this way; that is the watchdog's job.

## Driving from a controller

Running the agent on a real machine and the CLI on the phone gives you a
current model, a fast CPU, and a session Android will not kill. What makes it
practical is how the controller reaches the phone.

Running ssh for every verb is slow. Termux's sshd forks a shell for each
command, about 0.45 s, and connection multiplexing does not remove that
cost. Instead, `--device my-phone` forwards the daemon's unix socket:

```
ssh -o ControlMaster=no -o ExitOnForwardFailure=yes -f -N \
    -L $TMPDIR/phone-my-phone.sock:/data/data/com.termux/files/usr/tmp/phone-shell.sock my-phone
```

The forward is set up once and reused. Afterwards the sshd on the phone does
not fork anything; it passes bytes to a process that is already running. The
same round trip went from 0.449 s to 0.066 s. With `PHONE_SHELL_SOCK`
pointing at the forward, every shell verb runs unchanged on the controller.
`phone --device my-phone --print-link` prints the forward command, and
`--print-plan` prints how a verb would be carried out.

The forward does not use an existing ssh control master. Asking a master to
add a stream-local forward is accepted and then never created. Lanes get
their own forwarded socket (`phone-my-phone-<lane>.sock`), so one driver
cannot replace another driver's forward.

### Three kinds of verb

Not every verb can use the forward:

| kind | verbs | how they run from a controller |
|---|---|---|
| shell verbs | everything that needs shell uid: `look`, `tap`, `open`, `sh`, `display`, `lease`, ... | locally, against the forwarded socket |
| termux verbs | `say`, `listen`, `notifs`, `notify`, `battery`, `torch`, `where`, `clip`, `photo`, `watchdog` | on the phone, as the Termux app, over ssh: `ssh my-phone phone <verb> ...` |
| binary verbs | `screen` | on the phone over ssh, with the PNG streamed back on stdout and checked for the PNG signature before it is written |

Termux verbs cannot use the forward because the forwarded socket runs at
shell uid, and Termux's binaries live in an app-private prefix that shell
uid cannot read. Binary verbs cannot use it because the daemon's protocol is
text. Each ssh hop costs about 0.45 s, a reasonable price for a verb that
otherwise could not run from a controller at all.

The program run on the phone is `$PHONE_REMOTE_BIN` (default `phone`). This
applies to termux verbs, binary verbs, the remote half of `log`, and
starting a lane's daemon. The hop carries the display (`--display N`,
whenever one other than 0 is addressed) and `PHONE_ACTOR` (whenever it is
set), which ssh would not forward on its own. It clears `PHONE_DEVICE`, so
the copy on the phone never hops onward to another device, and it clears
`PHONE_LANE`, `PHONE_SHELL_SOCK` and `PHONE_DISPLAY`, so the phone's own
config file cannot point the verb's lease check or its screen anywhere other
than where the controller aimed it.

`log` needs no shell, so it never sets up a forward. A phone that cannot be
reached does not hide the controller's half of the record.

A verb `phone` does not have is refused before any of this: `phone: unknown
verb ...` and exit 2, with no ssh hop and no forward, whether or not the
phone is reachable.

## Leases

A lease says who is driving a display. It lives inside the shell daemon,
which runs on the phone, so it arbitrates local and remote drivers the same
way. Leases are kept in the daemon's memory, keyed by display, and every
check-and-set takes the daemon's own lease lock. The daemon serves one
request at a time anyway, but the lease should not depend on that staying
true.

- **Per display.** `phone --display N lease acquire --as <name>` holds
  display N only. Display 0 is the person's screen and gets no special
  treatment: take its lease before touching it.
- **TTL.** The default is 300 s (`--ttl`). A driver that crashes holding a
  lease must not lock the phone forever.
- **Gated in the CLI, not the daemon.** Before a mutating verb runs, `phone`
  asks the daemon who holds the display, and refuses with exit 5 if someone
  else does. The check is in the CLI because termux verbs such as `say`,
  `photo` and `torch` never reach the daemon. Whether a call mutates is
  decided from its parsed arguments, not the verb's name alone: `scan --tap`
  is gated, `media` only with a transport action, `clip` only for `set`,
  `reply` unless it is `--list`, and a form that only prints what it would
  do (`--print-only`, `--print-url`, `--dry-run`) is not.
- **Displays named as arguments.** `display rm` and `display move` act on
  the displays they name, not on `--display`, so they ask the lease of each
  one: `rm` of a display someone else holds exits 5, `rm --all` leaves those
  displays and names their holders, and `move` checks both the display the
  app leaves and the one it goes to.
- **Reads are never gated.** Watching must not require taking control, or a
  second agent looking at the screen would lock out the one using it.
  `look`, `find`, `ui`, `notifs`, `screen`, `foreground`, `media` without
  an action, `clip get`, `reply --list` and `scan` without `--tap` run
  while someone else holds the lease. `scan` without `--tap` scrolls but
  commits nothing.
- **Who you are** is `--as`, else `PHONE_ACTOR`, else `anon`. A holder is
  one word (letters, digits and `._@:+-`, at most 64 characters), because
  the daemon's lease protocol is a line split on spaces; any other name is
  refused with exit 2 before anything is sent.
- **Lanes do not share leases.** Two drivers in one lane arbitrate. Drivers
  in different lanes do not see each other's leases. This is acceptable only
  because lanes are opt-in.
- **No daemon, no arbitration.** If the shell daemon is not running, nothing
  holds a lease and verbs act. `PHONE_NO_LEASE=1` turns the gate off on
  purpose.

## The ledger

The CLI is the one place every action passes through, so it is where the
record is written. Each line of `~/.local/state/parallel-root/actions.jsonl`
(or `$PHONE_LEDGER`) is a JSON object:

| field | meaning |
|---|---|
| `ts` | Unix time |
| `verb` | the verb |
| `kind` | `act` (changed something: send, tap, type, play, torch, ...) or `read` (read personal data: notifications, the screen, location, ...) |
| `actor` | `PHONE_ACTOR`, or `anon` |
| `ms` | process start to the moment of recording, which for a one-verb CLI is how long the verb took |
| `rc` | 0 if it worked |
| `detail` | what was asked, which can include message text |
| `result` | what happened |

Mechanical reads such as `ui`, `find`, `battery` and `apps` are not
recorded. A record too noisy to read is not useful. The file is created with
mode 0600 because it holds message text and contact names.

**Two halves, merged when read.** From a controller, shell verbs write their
line on the controller, because the controller runs them against the
forwarded socket. Termux verbs write theirs on the phone, because the phone
runs them. `phone --device my-phone log` reads both halves (the phone's over
ssh), labels each row with its origin, and merges them by time. Writing
across the hop at the time of each action would put an ssh round trip back
on the path the forward exists to keep fast. `--kind`, `--actor` and
`--limit` travel to the phone, so it filters its half before it limits it.
`--limit 0` means everything; the phone's half is then capped at 5000 rows.
If the phone's half cannot be read, or comes back at that cap, `log` prints
what it has with a warning and exits 3, so a partial record never looks
complete.

```sh
phone --device my-phone log --limit 20
phone log --kind act --actor agent-a --json
```

## The bridge

The shell uid can read every notification through `dumpsys`, including its
reply actions. It cannot fire one. A reply action is a `PendingIntent`, a
live Binder token held in the system server, and `dumpsys` prints a
description of it, not the token. Only a bound `NotificationListenerService`
receives the real object. Shizuku cannot get around this: registering a
listener is checked on the server side and admits only system uids.

So `phone reply` needs an app. `android/bridge` is a notification listener
plus a server that reads and writes one line of JSON on device loopback port
8137, with the ops `ping`, `list`, `reply`, `action` and `dismiss`. A
controller reaches it through an ssh port forward, which `phone` sets up when
needed. The local end of the forward is `PHONE_BRIDGE_PORT`, so two drivers
on one controller each have their own forward.

**The token.** Loopback is not a permission boundary, because any app on
the phone can open a socket to 127.0.0.1. The bridge creates a random token
on first start and writes it to
`/sdcard/Android/data/parallelroot.bridge/files/token`. Under scoped storage
other apps cannot read that directory, but the shell uid can. `phone` reads
the token through the shell tier and sends it with every request, and the
bridge compares it in constant time. The token is what separates "has shell
on this phone" from "is some app on this phone". A controller that already
has the token can pass it as `PHONE_BRIDGE_TOKEN` and skip the read.

## `ask` and the router hook

`phone ask "<question>"` answers a question without a microphone, trying
these tiers in order:

1. **fast**: built-in handlers answer from device verbs: battery, time,
   date, what is playing, notifications, calendar. They take about a second.
   Each matches a whole question, give or take fillers such as "hey" or
   "please", never a word inside a longer sentence, so "add lunch to my
   calendar" is not answered with the calendar. `--no-fast` skips this
   tier.
2. **router**: an optional command, from `--router CMD` or `$PHONE_ROUTER`.
   `CMD` is split with `shlex`, and a brief is appended as one final
   argument. The brief asks for a short spoken answer, names this CLI's own
   path and the read-only verbs the router may run, and asks the router to
   reply `ESCALATE` if the question needs multi-step action, the screen, or
   sending something to a person. The answer is the last non-empty line of
   stdout that does not start with `[` and does not mention "tokens used".
3. otherwise **escalate**.

| exit | meaning |
|---|---|
| 0 | answered; the answer is on stdout and `tier: ...` on stderr |
| 4 | escalate: no tier could answer, or the router said `ESCALATE` |
| 5 | the router failed: it could not be started or split, exited non-zero, ran past `--router-timeout` (60 s), or printed no answer line |

From a controller, `ask` sets up no forward of its own before it starts.
A fast handler that needs the phone's shell brings the link up when it runs,
and declines when the phone cannot be reached, so a phone that is away costs
the fast tier, not the answer: the router still answers, and with no router
the question escalates (4).

A router that fails is never read as an answer: whatever it printed is
discarded, so an error message cannot be spoken back as if it were one. Nor
is a failure an escalation, which would quietly send every question to the
expensive tier the moment the router broke. The router's stdin is closed (it
reads end-of-file at once), so a router that looks for input there does not
sit waiting until the timeout. `--router ''` means no router even when
`PHONE_ROUTER` is set.

There is no default router. Two examples, with questions the fast tier
leaves alone:

```sh
phone ask --router 'codex exec --skip-git-repo-check' "who painted the sistine chapel"
phone ask --router 'claude -p' "is my phone about to die"
```

The router runs with its own sandbox and permission settings. If it needs to
run `phone` verbs to answer, allow it to in that agent's configuration. The
hook is a seam for building on: a voice loop, a messaging integration or a
custom agent can all sit behind it without changes to `phone`.

## The watchdog

Android kills Termux processes left idle, and a `while true` loop gets
killed with them. `phone watchdog --install` registers a script with
JobScheduler through `termux-job-scheduler --persisted true`. The OS runs it
periodically and keeps the registration across reboots. Each run:

| step | does | when |
|---|---|---|
| `wakelock` | `termux-wake-lock` | always |
| `sshd` | starts `sshd` if it is not running | always |
| `shizuku` | checks that `rish -c true` answers; raises or clears a "shell tier down" notification | always |
| `shelld` | `phone shelld --start` on the default lane, which reuses a live daemon, busy or not; passes when a daemon answers or is busy | only when the `shizuku` step passed; otherwise shown as skipped |
| `adb` | `adb connect $PHONE_ADB_ADDR` if no device is attached | only when `PHONE_ADB_ADDR` is set; otherwise shown as skipped |

A failing step is printed with a `!`. A ledger line is written only when a
step failed, recorded as a failure naming the steps, so that a run every 15
minutes does not bury the entries that matter.
