# Issue #30 — "Install Update" does nothing: diagnosis

Issue: https://github.com/bavanchun/ariadnev-skein/issues/30
Diagnosed: 2026-09-05. Evidence from the unified log store on the maintainer's
Mac, `/Applications/Skein.app` 1.2.1 (build 1122), pid 45326.

Status: **two separate defects.** Defect A (appcast signature placement) is
proven and is the reason the update does not install. Defect B (activation /
dead click) is the original hypothesis; it is **not reproduced** and the code
change written for it is **unverified** — a negative control is recorded below.

> **Correction, 2026-09-05 22:10.** An earlier revision of this report named
> Defect B as *the* root cause. That was wrong. Defect B explains the
> maintainer's *first* click doing nothing; it does not explain "does not
> install", and a control run on the unfixed binary behaved identically to the
> fixed one. Read Defect A first.

## Symptom (maintainer, verbatim)

> Không có gì cả — nút bấm không phản ứng

Sparkle offers 1.4.0. Clicking **Install Update** does nothing: no highlight, no
progress bar, no error, dialog stays put. Reached via the menu bar icon →
**Check for Updates…**.

## Defect A — `sparkle:edSignature` in the wrong place (PROVEN)

This is why the update does not install. It is a release-process defect, not app
code, and it has affected every release the project has published.

The appcast puts the signature as a **child element of `<item>`**:

```xml
<sparkle:edSignature>tyiWp/MuY0…oAA==</sparkle:edSignature>
<enclosure url="…/Skein-1.4.0.zip" sparkle:os="macos"
           length="6432768" type="application/octet-stream"/>
```

Sparkle reads it **only** from the enclosure's attribute dictionary:

- `Sparkle/SUAppcastItem.m:533` —
  `_signatures = [[SUSignatures alloc] initWithEd:[enclosure objectForKey:SUAppcastAttributeEDSignature]`
- `Sparkle/SUConstants.m:79` — that key is `@"sparkle:edSignature"`.
- Every appcast Sparkle itself ships (`Resources/SampleAppcast.xml`,
  `Tests/Resources/testappcast*.xml`, `TestApplication/sparkletestcast.xml`)
  writes it as an `<enclosure>` attribute.
- `sign_update --help`: *"this tool will output an EdDSA signature and length
  attributes to use for your update's appcast item **enclosure**"*, and it
  prints the pair ready to paste.

So the feed parses, the update is offered, it downloads, extracts and starts
installing — and dies at validation:

```
2026-09-05 22:02:44.211 E Autoupdate[84880:bff031] [org.sparkle-project.Sparkle:Sparkle]
  Error: The app has an EdDSA public key, but there is no EdDSA signature in
  the update, so the update will be rejected.
```

**The signatures themselves are correct.** All three published ZIPs were
downloaded and each one's Ed25519 signature from the appcast verified against
the app's `SUPublicEDKey`, with the declared `length` matching byte-for-byte:

| Release | Signature | Length |
|---|---|---|
| 1.4.0 | valid | 6 432 768, matches |
| 1.2.2 | valid | 6 178 231, matches |
| 1.2.1 | valid | 6 196 777, matches |

So the repair is a pure XML move: no rebuild, no re-signing, and it fixes
updating for every version already installed.

Source of the mistake: the Step 5 template in `docs/release-guide.md`, from
which every appcast has been hand-authored. Fixed there, along with a feed gate
in Pitfalls:

```bash
curl -s https://skein.ariadnev.com/appcast.xml | grep -c 'enclosure[^>]*sparkle:edSignature'
# 0 on the live feed; must equal the number of <item> entries
```

Remaining action, maintainer's call: republish `appcast.xml` as an asset on the
latest release with all three signatures moved onto their enclosures. The
Cloudflare Worker only proxies `releases/latest/download/appcast.xml` and needs
no change.

## Defect B — activation / dead click (NOT reproduced)

`Skein/Updates/UpdatesManager.swift:87` activates the app *before*
`updater.checkForUpdates()` at :89. The alert appears 4.1s later,
asynchronously. The `SPUStandardUserDriverDelegate` conformance at
`UpdatesManager.swift:116-153` never activates the app when Sparkle is about to
show the update window (`standardUserDriverWillHandleShowingUpdate` only posts a
notification) and does not implement `standardUserDriverWillFinishUpdateSession`
at all. Both selectors exist in the linked Sparkle 2.6.4 binary.

Skein is `LSUIElement` / `.accessory`. Once
`AppState.deactivate(withPolicy: .accessory)` (`AppState.swift:287-294`,
`NSApp.yieldActivation(to:)`) runs, the still-visible alert belongs to an
inactive accessory app, and can be buried behind other windows.

**The mechanism originally proposed here is refuted.** This report previously
argued that `NSButton.acceptsFirstMouse` is false, so a click on an inactive
app's button only re-activates and never fires. That is wrong on this machine:

```
$ swift afm-check.swift
plain acceptsFirstMouse: true
rounded acceptsFirstMouse: true
```

`NSButton` takes click-through. A click on **Install Update** in an inactive
Skein window both activates the app *and* fires the action, so losing activation
cannot make the button dead. At worst it buries the alert. The log therefore
proves the button was never *fired*; it does not prove it was *clicked*.

Reachable deactivation call sites: only `MenuBarManager.swift:372`
(`showApplicationMenus()`, via the `controlItem.$state` pipeline at
`MenuBarManager.swift:151-224`). `AppDelegate.swift:64`
(`applicationShouldTerminateAfterLastWindowClosed`) does **not** apply while the
alert is open — AppKit only sends that when the *last* window closes, and the
alert is a window. That pipeline's guard at `MenuBarManager.swift:171`
(`appState.settingsWindow?.isVisible == false`) protects the settings window
from exactly this — but knows nothing about Sparkle's alert.

The codebase already documents this failure class at
`UpdatesManager.swift:96-101`, for Sparkle's *permission* prompt, which it fixes
by suppressing that prompt outright. The update alert got no equivalent.

## Evidence for Defect B (pre-fix, maintainer's live session)

Skein has zero WebKit code (`grep -rn "WKWebView\|import WebKit" Skein/` → none).
Sparkle renders release notes in a WKWebView
(`-[SUUpdateAlert _createReleaseNotesViewPreferringPlainText:]`). So WebKit page
lifecycle in Skein's log **is** the update alert's lifecycle.

Alert lifetime — exactly one alert existed all day, on screen 2h45m:

    16:45:45.841  WebProcessPool::createWebPage / addExistingWebPage (pageProxyID=7, webPageID=8)
    19:31:34.212  WebPageProxy::close

`trackMouse send action on mouseUp` is AppKit's Activity-level signal that a
control's action fired from a real mouse-up. Complete list 16:45→19:35:

    16:45:38.952 / 16:45:40.240 / 16:45:41.730   before the alert existed
    19:28:12.139
    19:31:34.183 / 19:31:35.075

**Zero between 16:45:45.841 and 19:28:12.139** — none in the first 2h42m the
alert was up.

The two failed clicks, from launchservicesd SETFRONT + WebKit occlusion state
(pid 2669 = /Applications/Orca.app):

    16:47:02.498  SETFRONT pid=45326 (Skein)         click #1 lands on the alert
    16:47:02.574  occluded 1 -> 0, viewIsBecomingVisible   alert forward, NO action fired
    16:47:03.791  SETFRONT pid=2669                  1.22s later, front gone
    16:47:05.790  SETFRONT pid=45326                 click #2
    16:47:06.256  SETFRONT pid=2669                  0.47s later

0.47s is too fast for a deliberate human app switch. Consistent with a
programmatic `NSApp.yieldActivation(to:)`.

The 19:31:34 teardown, in order — a fresh `checkForUpdates()` aborting the stale
session, not an install:

    19:31:34.183  trackMouse send action on mouseUp / sendActionFrom: / sendAction:
    19:31:34.187  WebPageProxy::stopLoading
    19:31:34.212  WebPageProxy::close
    19:31:34.232  xpc activating connection name=com.ariadnev.Skein-spks
    19:31:34.232  xpc bootstrap look-up failed: [3: No such process]  (expected, no installer running)
    19:31:35.075  trackMouse send action on mouseUp
    19:31:35.146  SetFrontProcess -> Skein loses front

`SULastCheckTime` = 19:31:34 confirms a new check, not an install.

Negative evidence: no `org.sparkle-project.Sparkle/` cache dir under
`~/Library/Caches/com.ariadnev.Skein/` (only `WebKit`); zero lines under
subsystem `org.sparkle-project.Sparkle`; no `Autoupdate`/`Updater` process; no
Gatekeeper/syspolicyd evaluation; no ZIP download; `SUSkippedVersion` absent.
Working comparison on the same machine: CodexBar's Sparkle cache has
`Installation`, `Launcher`, `PersistentDownloads`.

## Hypotheses eliminated

- **Ad-hoc `Autoupdate` signature.** Not the first failure: Autoupdate does
  launch and does reach the install step (it is the process that logs the
  rejection above). Its signature is nonetheless wrong — the shipped 1.2.1
  carries `Signature=adhoc`, `TeamIdentifier=not set` — and it has now been
  added to the codesign sequence in `docs/release-guide.md`, with a loop that
  fails the release if any nested binary is still ad-hoc.
- **Buttons off-screen.** `NSWindow Frame SUUpdateAlert = 590 546 620 402` on a
  live 3008x1692 main display at (0,0). Fully on-screen.
- **Permissions / disk.** `/Applications/Skein.app` owned by `vchun`, writable;
  160Gi free.
- **Feed / Worker.** The appcast parsed fine — 1.4.0 was offered, and the
  CFNetwork fetch at 16:45:44.749 succeeded with a clean trust evaluation.
- **`AppState` frontmost pipeline** (`AppState.swift:136-152`). It only refreshes
  the image cache. Not a deactivation path.
- **Quarantine on the non-notarized helper bundles** — issue #30's leading
  hypothesis. Disproven: the download, extraction and install all ran, through
  those exact helpers. The failure is later, at signature validation.
- **"The download never started."** Also from the issue, inferred from an empty
  `~/Library/Caches/com.ariadnev.Skein/`. Disproven by
  `nw_endpoint_flow_connect […]:443` at 22:02:42.452 and the
  Downloading → Extracting → Installing sequence that follows.

## Why now

`git log --follow Skein/Updates/UpdatesManager.swift` shows only two commits,
both pure renames (`07b2715`, `717f557`). The defect is inherited unchanged from
upstream Ice. No release had ever been self-updated on hardware:
`plans/260828-2226-audit-fixes-p0-p3/phase-01-p0-v1.2.2-patch.md:92` still reads
"self-update on a real Mac pending maintainer."

## Blast radius

Every window `SPUStandardUserDriver` shows: update alert, download/extract
progress, "You're up to date", Sparkle error alerts. Both entry points:
`ControlItem.swift:536` (menu bar) and `AboutSettingsPane.swift:123` (About
pane). The **scheduled** check is worse — it never reaches
`UpdatesManager.swift:87`, so there is no activation at all, and
`standardUserDriverShouldHandleShowingScheduledUpdate` adds none.

## Defect B — what was implemented, and why it was dropped

Fix shape **B** was implemented (+42/-0) and then **reverted**. It is not in the
PR. What follows is the record of what it was and why it is not shipping.

- `Skein/Main/AppState.swift` — `isUpdateSessionActive`;
  `deactivate(withPolicy:)` early-returns while it is set; `beginUpdateSession()`
  / `endUpdateSession()`.
- `Skein/Updates/UpdatesManager.swift` — `beginUpdateSession()` in
  `standardUserDriverWillHandleShowingUpdate`; a new
  `standardUserDriverWillFinishUpdateSession()` calling `endUpdateSession()`.

The guard was placed in `AppState.deactivate(withPolicy:)` rather than in
`MenuBarManager` because that is the single choke point every call site passes
through.

### Why it was dropped

**1. Its mechanism is refuted.** `NSButton` takes click-through on this machine
(probe above), so lost activation cannot produce a dead button. The change fixes
a cause that was never demonstrated to exist.

**2. "The flag cannot stick" was wrong — in the default configuration it always
sticks.** The claim rested on `dismissUpdateInstallation`
(`SPUUserDriver.h:270-274`, `SPUStandardUserDriver.m:908-914`) always arriving.
It does not arrive on the path this app takes by default:

- `Info.plist:6-7` sets `SUEnableAutomaticChecks` — scheduled checks are on.
- `UpdatesManager.swift:123-127` returns `false` when `NSApp.isActive` is false,
  which for an accessory app is nearly always.
- Sparkle then takes `SPUStandardUserDriver.m:293-306`: it calls
  `standardUserDriverWillHandleShowingUpdate:NO` and shows **nothing**. No alert,
  no dismissal, so `standardUserDriverWillFinishUpdateSession` never fires.
- the dropped diff called `beginUpdateSession()` unconditionally at that
  callback, ignoring the `handleShowingUpdate` argument — so the deferred case
  set the flag too.

So after the first scheduled check that finds an update, `isUpdateSessionActive`
stays `true` for the process lifetime and `deactivate(withPolicy:)` early-returns
forever — *including its `NSApp.setActivationPolicy(policy)` half*
(`AppState.swift:293` on `main`). `MenuBarManager.showApplicationMenus()` (`:366-374`)
then cannot restore `.accessory`, and hiding application menus is on by default
(`AdvancedSettingsManager.swift:13`). The user is left with a Dock icon, a
Cmd-Tab entry, and their own app menus hidden, permanently, with no way back
short of relaunching.

That is a real, user-visible regression traded for an unverified benefit. The
diff is kept above rather than shipped.

**If hardening is ever wanted after an actual reproduction**, the regression-free
shape is not a latch in `AppState` but one more clause in the existing pipeline
guard at `MenuBarManager.swift:167-173`, beside `settingsWindow?.isVisible`:
skip the auto hide/show cycle while a window with identifier `SUUpdateAlert`
(`SUUpdateAlert.xib:23`) is visible. Symmetric with the settings-window guard,
no delegate state, no latch. Still unverified — do not ship it either.

### Negative control — the attribution fails

Verification used real CGEvent clicks (`cliclick`). `AXPress` was deliberately
avoided: it bypasses mouse tracking and would succeed with the bug present.

| Run | Binary | Result |
|---|---|---|
| Fixed 1.2.1 (PID 79200) | contains the guard | `22:02:42.333 (AppKit) trackMouse send action on mouseUp` → Downloading |
| Control 1.2.1 (PID 89599) | `strings \| grep -c "update session is active"` = **0** | `22:06:33.166 (AppKit) trackMouse send action on mouseUp` → Downloading |

Both reached Downloading → Extracting → Installing → **Update Error!**, and both
died on the same EdDSA rejection.

The guard's `Logger.appState.debug` line printed **0 times** in the fixed run,
while 1364 `com.ariadnev.Skein:` lines were captured in the same stream — so
`deactivate(withPolicy:)` was never called and the guard was never exercised.

A freshly launched app does not recreate the maintainer's conditions (the app
had been running for hours with the debounced frontmost pipeline in flight).
**The change is plausible hardening. It is not attributable to any observed
repair.**

## Open, not proven

1. Which deactivation call site fired at 16:47 in the maintainer's session.
   `Logger.info`/`.debug` are memory-only in os_log and are not persisted to
   `log show`, so the absence of "Showing application menus" proves nothing.
   (`log stream --level debug` *does* capture them live — that is how the
   post-fix runs were instrumented.)
2. Whether Defect B reproduces at all once Defect A is fixed. It cannot be
   settled without a long-running app and a working feed, and the guardrail
   override that permitted touching `/Applications` and `com.ariadnev.Skein`
   defaults is spent — a further hardware run needs fresh maintainer consent.

## Follow-ups

Done in this session:

- `docs/release-guide.md` — Step 5 template corrected; `Autoupdate` added to the
  codesign sequence with an ad-hoc assertion; Pitfalls entry with the feed gate;
  release checklist updated.
- `plans/handoffs/02c-install-escort-v1.2.2-20260828.md` — the claim that a
  Sparkle-delivered update sidesteps the problem because "Sparkle validates the
  EdDSA signature itself" is marked superseded.
- `plans/260828-2226-audit-fixes-p0-p3/phase-01-p0-v1.2.2-patch.md:92` — the
  long-open "self-update works on a real Mac" box closed with the real, negative
  result.

Outstanding:

- Republish `appcast.xml` on the latest release with the signatures moved.
  Maintainer's call; a corrected copy is prepared.
- Re-scope issue #30. Its "Ruled out" section wrongly excludes a feed defect,
  its leading hypothesis (quarantine) is disproven, and "Evidence still needed"
  item 2 wrongly says the agent's shell could not read the log store — `log` was
  shadowed by a zsh alias; `/usr/bin/log stream --level debug` works. Item 1 is
  answered.
- Consider generating the appcast from a script under `Scripts/` rather than
  hand-authoring it from a doc template, given this failure survived three
  releases.

## Kongming advisory

The first agent (`a50735632a4306d40`) was stopped by the maintainer at
2026-09-05 20:20 before returning counsel; no findings came from it and none may
be assumed. A second checkpoint was opened at 22:15 with the full two-defect
evidence, the negative control, and four questions: what to do with the
unattributed Swift change, whether the Defect B evidence has a better
explanation, how to re-scope issue #30, and whether the appcast should be
script-generated.
