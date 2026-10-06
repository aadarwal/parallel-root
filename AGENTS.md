# Working on this repository

These are instructions for coding agents changing parallel-root itself. To
learn how to *drive a phone* with it, read `plugin/skills/phone/SKILL.md`.

## Layout

```
bin/phone                 the CLI: ONE file, python3 stdlib only
android/vdisplay/         display holder: a dex run by app_process as shell (build.sh)
android/bridge/           optional app: notification listener + loopback bridge (build.sh)
plugin/                   the agent plugin; skills/phone (method + map.md), skills/screens
install/                  termux-setup.sh (on the phone), install-controller.sh
tests/                    test-phone.sh, test-displays.sh, check-skill-verbs.py, run-all.sh
docs/                     design.md (the contract), setup, architecture, displays, configuration
```

`docs/design.md` is the contract. If code, skills and docs disagree, the
design wins, or the design is changed on purpose in the same change.

## Testing

```sh
bash tests/run-all.sh
```

Run it before you report any change as done. It needs no phone and must
pass on Linux and macOS. Device tests are opt-in: the device half of
`tests/test-displays.sh` runs only with `PHONE_TEST_DEVICE=<ssh-host>`, and
its two steps that touch the person's screen run only with
`PHONE_TEST_INTRUSIVE=1`. Never set either unless the human asked you to and
named the phone.

The suites set `PHONE_LEDGER` and `PHONE_CONFIG` to temporary paths. New
tests must do the same, and must use synthetic fixtures.

## Rules

- **`bin/phone` stays one file**, Python 3.8+ standard library only. The
  phone runs a single deployed copy, and copying one file is the install. Do
  not split it, add a package, or add a dependency.
- **Keep the explanatory comments.** They record measurements and the
  reasons behind decisions. Edit one only to keep it true after your change.
- **Verify by observation.** Exit codes on Android do not prove success. Do
  not claim device behaviour you did not observe; say what was and was not
  tested.
- **Skills only teach verbs the CLI has.** `tests/check-skill-verbs.py`
  enforces this. Update skills and docs with any verb change.
- **Exit codes**: 1 the verb ran and the answer is no, or an act could not
  be confirmed; 2 usage; 3 no device or no shell tier; 4 failed or not
  found, including an act that was watched and did not happen; 5 refused.
  Do not reuse them for other meanings.
- **No personal data, anywhere.** No names, emails, phone numbers,
  hostnames, device names, tailnet names or addresses, or real notification
  or message content, in code, comments, fixtures, docs or commit messages.
  Use `my-phone`, `alice` and `<phone-ip>`.
- **No machine-specific defaults.** Devices and build hosts come from the
  environment (`PHONE_DEVICE`, `VD_BUILD_HOST`); `phone` itself can also
  read `PHONE_*` settings from its config file.
- **Never commit** keystores, tokens, ledgers, screenshots or build outputs.
- **Do not contact a phone** (ssh, `phone --device`, `build.sh install`)
  unless the human asked you to.

## Style

Plain, direct and specific. Short paragraphs, tables where they help, real
commands. In code, a comment says why something is the way it is, and what
was measured.
