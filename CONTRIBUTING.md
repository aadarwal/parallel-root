# Contributing

Thanks for helping. This page covers how to test a change, the conventions
the code follows, and how to add what you learned about a phone or an app.

## Run the tests

```sh
bash tests/run-all.sh
```

This needs no phone. The suites run against synthetic fixtures, with a local
`sh` standing in for the device shell, and they set `PHONE_LEDGER` and
`PHONE_CONFIG` to temporary paths so they never touch your real ones. CI
runs the same command on Linux and macOS.

The device half of `tests/test-displays.sh` is opt-in:

```sh
PHONE_TEST_DEVICE=my-phone bash tests/test-displays.sh
PHONE_TEST_DEVICE=my-phone PHONE_TEST_INTRUSIVE=1 bash tests/test-displays.sh
```

It releases only the displays it created and never touches display 0 beyond
reading it. With `PHONE_TEST_INTRUSIVE=1` it also runs the two steps that put
something on the screen of whoever is holding the phone. Run that only on a
phone you are holding.

`tests/check-skill-verbs.py` fails if a skill teaches a verb the CLI does
not have. If you add or rename a verb, update the skills in the same change.

## Conventions

- **`bin/phone` is one file, Python 3.8+ standard library only.** The phone
  runs a single deployed copy, not a checkout, and copying one file is the
  whole install. Do not split it into a package and do not add
  dependencies.
- **Comments explain why, and carry the measurements.** Many comments in
  `bin/phone` record what was tried, what it cost, and how it failed:
  "measured 0.449 s → 0.066 s", "clean at 4 KB, half at 9 KB, none at
  61 KB". Keep them. When a change makes one untrue, correct it; do not
  delete it.
- **Verify by observation.** An exit code is not evidence on Android:
  `input tap`, `am start` and `content query` all exit 0 when they fail. A
  change that claims to fix behaviour on a device should say what was
  observed, on which device and Android version, and what changed when the
  input changed.
- **Three-valued answers.** "Could not check" is not "no". A probe that
  cannot reach the device must say so instead of reporting absence.
- **Exit codes keep their meaning**: 1 the verb ran and the answer is no
  (nothing matched, nothing was heard) or an act could not be confirmed, 2
  usage, 3 no device or no shell tier, 4 failed or not found (an act that was
  watched and did not happen is a failure), 5 refused (a held lease, one app
  one display, a read that could not be verified).
- **No defaults that name a machine.** Device names, build hosts and
  addresses come from the environment or the config file, never from the
  code.
- **Android pieces build without Gradle**: `javac`, `d8`, and for the bridge
  `aapt2`, `zipalign` and `apksigner`, driven by each `build.sh`.

## Writing a per-app skill

The `phone` skill teaches method. A per-app skill teaches one app's
territory. Put it in its own plugin or in `plugin/skills/<app>/SKILL.md`,
and build it from what you observed on a device, not from memory of how the
app used to work. A short template:

```markdown
---
name: example-app
description: Drive Example App on a phone: <the tasks this covers>. Use when <the trigger>.
---

# Example App

Verified on <device>, Android <version>, Example App <version>, <date>.

## Deep links
Which intents and URLs the app honours, with the exact `phone open` /
`phone sh 'am start ...'` line, and which ones it accepts and then ignores.

## Screen grammar
How its screens are laid out: the labels and resource ids that are stable,
the ones that change between visits, where lists scroll, and what
`phone find --all` returns on the screens that matter.

## Overlays
Floating bars, sheets and banners that sit over content and take taps
meant for something underneath, and how to get a target clear of them.

## Refusals
What the app will not do from here: secondary displays, FLAG_SECURE
screens, flows that require a person.

## Costs
How many dumps a task takes, and which shortcuts (`tap --label --look`,
`scan`) save turns.

## Not tested, on purpose
Anything that would contact a person, spend money or risk the control
channel, and so was deliberately not tried.
```

Dated findings that would crowd the skill can go in a `map.md` beside it,
in the format of the phone map (see "Adding a map entry" below), with the
skill pointing to it. A skill under `plugin/skills/` is checked by
`tests/check-skill-verbs.py` like the others, so it can teach only verbs
`phone` has. One kept in a plugin of its own is not checked, so hold it to
the verbs `phone --help` lists.

Per-app skills must follow the same rules as the `phone` skill: confirm
before anything consequential, never read out codes, never touch the control
channel. Use invented names and content in every example and fixture.

## Adding a map entry

`plugin/skills/phone/map.md` records findings established by trying them on
a reference device. To add one:

- put it under the section it belongs to, as a `###` heading that states the
  finding;
- start with the **route** that worked (state, intent or screen) and the
  **date and build** it was verified on, for example
  `**Route:** state. **Verified:** 2026-09-01, Android 16 (sdk 36), Pixel 10.`;
- give the exact command and the output that mattered, trimmed;
- include failed attempts. They are often the more useful half;
- when a later change fixes something an entry describes, keep the entry and
  mark it **fixed** with the date.

Platform facts (exit codes, dump costs, display mechanics) belong in the
map. Facts about one person's phone (their accounts, contacts, installed
apps, messages) do not.

## Never commit

- personal data of any kind: names, phone numbers, email addresses,
  locations, real notification or message content, contact lists, calendar
  entries, or installed-app lists that are really one person's habits;
- device names, ssh aliases, hostnames, tailnet names or addresses. Write
  `my-phone`, `<phone-ip>` and `alice`;
- ledger files, screenshots and photos taken from a real phone;
- keystores (`*.keystore`, `*.jks`), tokens and keys;
- build outputs (`android/*/build/`, `*.apk`, `*.jar`, `*.dex`).

Test fixtures are synthetic: invented people, invented messages, and
invented packages wherever a real one is not the point. `.gitignore` covers
the build outputs and keystores, but it cannot catch a real message pasted
into a fixture. Read your diff before you push.
