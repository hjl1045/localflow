# Bug reports and crash reports

How a problem gets from someone's Mac into a tracked issue, and what to do with
one once it arrives.

## What the app does

Two entry points, one payload:

| Trigger | What happens |
| -- | -- |
| Menu bar → **Report an issue…** | Report window opens with the machine's configuration already collected |
| A crash on the previous run | Short "LocalFlow quit unexpectedly" alert at the next launch → the same window, with the crash report attached |

The window shows the **entire payload in the same text that gets sent**, then
offers three ways out: **Send…** (opens a mail draft), **Copy**, **Save…**.
Nothing is transmitted by the app itself, ever — there is no background upload
and no telemetry.

The payload is assembled in one place, `Sources/LocalFlow/Diagnostics.swift`.
It carries app/macOS/Mac versions, which ASR model and language, the cleanup
setting and Ollama health, both hotkeys, the microphone and Accessibility
permission states, launch-at-login, and up to 40 recent log lines.

Two things it deliberately doesn't carry:

- **Transcript text** — opt-in per report, via a checkbox that only appears
  when there is a recent dictation. It's the most useful field for a dictation
  bug and the most sensitive thing the app holds, so it can't be a default.
- **Audio** — no path attaches a recording.

The log tail is safe to include unreviewed, and that's a property worth not
breaking: every log call in this codebase records *counts*, never content
(`transcript: 64 chars`, `inject: chars=186`), and `os_log` redacts
interpolated strings as `<private>` unless explicitly marked public. Verified
in real output 2026-09-10. **If you ever log a transcript, this stops being
true** — re-check before shipping.

## Where reports land

Mail sent from the report window goes to a **Linear team intake address** for
The Autonomes team, which turns the email into an issue with the sender's
address attached, so a report is answerable.

### Why not the Linear API

A Linear API key grants read/write to an entire workspace, and Linear has no
write-only intake token. LocalFlow ships as a public, MIT-licensed binary, so a
key embedded in it would hand the whole workspace to anyone who ran `strings`
on the download. A relay service holding the key server-side would work — that
is what Echo Story does — but it means running a service and exposing a public
endpoint for an app that otherwise makes no off-machine network calls at all.
Email costs neither and keeps the payload reviewable by the person sending it.

### Rotating the intake address

The address ships inside the app, so it is public by necessity. The local part
carries a random token, so it isn't guessable — but if it ever gets scraped and
spammed:

1. Linear → Settings → Teams → **The Autonomes** → General → **Create issues
   by email** → the regenerate button beside the address. This invalidates the
   old address immediately.
2. Update `intakeAddress` in `Sources/LocalFlow/Feedback.swift`.
3. Ship a release. Older installs will mail a dead address, so mention it in
   the release notes.

Turning the toggle off entirely disables the address without deleting the
issues it created.

## Reading a crash report

macOS writes crash reports to `~/Library/Logs/DiagnosticReports/` as `.ips`
files whether or not the app asks. LocalFlow installs **no** crash handler: the
things that actually kill a Swift app arrive as SIGILL/SIGTRAP, which
`NSSetUncaughtExceptionHandler` never sees, so an in-process handler would
catch almost nothing while adding a component that runs during a crash. The app
only *notices* an unreported one at the next launch
(`Sources/LocalFlow/CrashReports.swift`), offers it once, and stays quiet about
reports older than a week.

Apple's own aggregation (Xcode → Organizer → Crashes) is **not** available: it
only receives reports for apps distributed through the App Store or TestFlight,
and LocalFlow ships as a notarized zip. Notarization does not change this.

`NSApplicationCrashOnExceptions` is set in `Support/Info.plist` on purpose.
Without it AppKit catches an uncaught `NSException` in the main event loop and
carries on with the app in an undefined state and **nothing written to
DiagnosticReports** — the failure is invisible to the user, to the crash
prompt, and to us. The Cocoa frameworks are not exception-safe, so "carried on"
is a fiction; crashing is the honest outcome.

### Symbolicating one

A release build is optimized, so a crash report from a downloaded build is a
list of addresses. The names live only in the `.dSYM`, which `swift build`
overwrites on the next build — so `make zip` now archives it beside the
artifact as `dist.noindex/LocalFlow-<version>.dSYM.zip`, and **it must be uploaded to
the GitHub Release along with the app zip.**

This is not hypothetical: the shipped v0.2.1 binary (UUID `E154BA96…`) had no
surviving dSYM anywhere on the build machine, so any crash report from it is
unreadable.

Match a report to its symbols by UUID before trusting anything:

```sh
# UUID the crash report was built from — see the "images" section of the .ips
dwarfdump --uuid LocalFlow-<version>.dSYM
```

Then symbolicate with `atos`, pointing at the matching dSYM:

```sh
atos -o LocalFlow-<version>.dSYM/Contents/Resources/DWARF/LocalFlow \
     -arch arm64 -l <load address> <frame address>
```

If the UUIDs don't match, the symbols are from a different build and the output
will be confidently wrong.

## Reading the log by hand

The report includes a log tail, but for a live problem read it directly. Note
the absolute path — `log` is a common shell alias:

```sh
/usr/bin/log show --predicate 'subsystem == "ai.xdlab.LocalFlow"' --last 30m --style compact
/usr/bin/log stream --predicate 'subsystem == "ai.xdlab.LocalFlow"'   # live
```

Categories: `pipeline`, `transcribe`, `inject`, `updates`, `loginitem`,
`crash`, `diagnostics`, `feedback`.

## Checking the report without clicking

The report the window sends can be printed from a terminal, which is how the
non-visual half gets tested:

```sh
dist.noindex/LocalFlow.app/Contents/MacOS/LocalFlow --diagnostics       # the full report
dist.noindex/LocalFlow.app/Contents/MacOS/LocalFlow --diagnostics-mail  # the trimmed email body + mailto URL length
```

Run these from the **app bundle**, not `.build/release/LocalFlow` — the bare
executable has no `Info.plist`, so every version field reads `unknown`.

The email variant is capped at 4000 characters of body, trimming the oldest log
lines first, because mail clients and `NSWorkspace.open` both get unreliable
with very long URLs and a draft that silently fails to open is worse than a
short one. Copy and Save always carry the untrimmed report.
