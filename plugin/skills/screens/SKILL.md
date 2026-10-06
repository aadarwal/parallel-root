---
name: screens
description: Work on a phone that other agents are also using — take a screen of your own, so several agents drive different apps at once without touching the person's. Use when another agent holds the phone, when the work would disturb what the person is looking at, or when a task needs more than one app driven at the same time.
---

# More than one agent on one phone

A phone has one screen, and that is why it has a lease: two drivers on one
screen is one agent typing into another agent's chat. A **display** is the way
out. It is a real, trusted screen — its own resumed activity, its own focus,
its own input — that the person cannot see and does not lose their phone to.

But the first question is not "which display". It is whether you need one.

## Most work needs no display at all

Routes 1 and 2 of the tier ladder are already parallel-safe. `content query`,
`cmd <svc>`, `dumpsys`, `settings`, `am start` — these go through binder to
system services that handle concurrent callers all day. Ten agents reading
notifications, media state, the calendar and the battery at once is fine, and
none of them needs to take anything.

**Reads are never leased**, on any display. Watching must not require taking
control, or a second pair of eyes becomes an outage. `look`, `find`, `ui`,
`notifs`, `screen`, `foreground` work while somebody else is driving.

So a display is the residual answer, exactly like the screen tier it exists
for: you need one when you must **act on the screen** and the screen is taken
or is the person's.

## Take one, work, give it back

```
d=$(phone display create)        # ~4s, invisible to the person
phone --display $d open <app>
phone --display $d look / find / tap / type / screen
phone display rm $d              # closes what was on it
```

`--display` is global, like `--device`: every verb after it addresses that
screen. Nothing you do there reaches display 0.

**Release the displays you created**, by id: `phone display rm $d`. A display
is a held process, and `display rm` takes its apps with it. An abandoned
display is an app of the person's still running, forever. `phone display rm
--all` puts the phone back to one screen; keep it for a phone no other agent
is using. It leaves a display somebody else holds a lease on, and says whose.

## One app, one display

`phone open` refuses a package that is already somewhere else, exit 5. This is
not tidiness. `am start --display` on an existing task does not make a second
copy — it **moves** the task, and the agent driving it loses its app mid-turn
with no error anywhere.

There is one process, one logged-in account and one notification stream behind
an app however many screens point at it. Displays multiply screens; they never
multiply apps. Two agents in the same chat of one messaging app, on two
displays, is the same failure the lease exists to prevent, reached by a
different road.

When you genuinely want it moved, say so:

```
phone display move <app> --to <display>
```

## Sharing the phone with other agents

`phone display ls` is the coordination surface — every screen, and what is on
it. Read it before you create anything.

```
0   Built-in Scr  1080x2424  dpi 420  internal  com.google.android.apps.nexuslauncher   <- the person's
6   pr-vd-1       1080x2424  dpi 420  virtual   com.android.chrome                      <- somebody's
```

The columns are id, name, size, density, type, then up to three packages with
a task there, topmost first.

The **lease is per display**. Take it on the display you are mutating, under a
one-word name that identifies you (`agent-b`, not `agent b`):

```
phone --display $d lease acquire --as <your-name>
...
phone --display $d lease release --as <your-name>
```

A held display refuses another driver's mutating verbs and names the holder —
`display rm` and `display move` included, for every display they touch.
Display 0 is a display like any other — take its lease before you touch the
person's screen, and expect to be refused.

If your bottleneck is shell throughput rather than the screen, take a **lane**
instead: `PHONE_LANE=<name>` gives you your own `shelld`, so a 3-second
`uiautomator dump` of yours is not 3 seconds nobody else can run a
`settings get` in. Measured: two 4-second commands, 8.6s shared, 4.3s in two
lanes. Lanes are opt-in and the default lane stays shared.

## What a display does not give you

The **microphone, the speaker, the notification shade and the person** are
singular no matter what `--display` says. `say`, `listen` and `notify` are
one-at-a-time, and voice is one conversation. Do not open two.

`FLAG_SECURE` content — banking apps, DRM video — renders **black** on any
display but the built-in one. That is enforced below the shell and root does
not help. If a screen comes back black, that is what happened; say so rather
than reporting an empty screen.

Some apps refuse a secondary display outright. `display create` succeeding
does not promise the app will land; verify with `phone --display $d
foreground` rather than assuming.

**Your display sleeps when the phone does.** It shares the person's power
group, so while the phone dozes an app on your display is resumed — `open`
and `foreground` still work — and draws nothing: `look` has no tree and
`screen` has no frame, and both say the phone is asleep. Waking your display
means waking the phone, which turns on the person's screen. Do not do that on
your own: say the phone is asleep, and let the person wake it, or plug it
in and keep it awake while it charges (`svc power stayon true`; it holds
only while the phone is plugged in).

## Showing your work

Headless is the default because the point is working without taking the phone
away from the person. When you want them to watch:

```
phone display create --visible   # a floating window on their screen
phone display move <app> --to 0  # or just hand it to their screen
```

A visible display reads and taps like any other. It cannot be screenshotted on
its own — Android composites it onto the built-in screen, so there is no
separate surface — use `phone screen` for pixels and you will see it as the
window it is.

## Leave it as you found it

Before you finish: `phone display ls`. If a display of yours is still there,
release it. If you moved one of the person's apps, move it back. If you took a
lease, release it. The next agent reads the same list you did.
