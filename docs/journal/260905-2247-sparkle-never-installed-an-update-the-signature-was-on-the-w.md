# Sparkle never installed an update: the signature was on the wrong element

**Date**: 2026-09-05 22:47
**Component**: updates/appcast
**Status**: Ongoing

## What happened

## What happened

Issue #30 was filed as *"Sparkle offers 1.4.0 but Install Update does not
install it"*. The reported symptom was a dead button. The actual defect was
upstream of the button entirely.

Every appcast this project ever published wrote the signature as a child
element:

```xml
<item>
  <sparkle:edSignature>…</sparkle:edSignature>
  <enclosure url="…" length="6432768" />
</item>
```

`SUAppcastItem` reads `sparkle:edSignature` from the **enclosure's attribute
dictionary** (`SUAppcastItem.m:533`, key from `SUConstants.m:79`). It never
looks at `<item>` children. So Sparkle downloaded the ZIP, found no signature,
and rejected it at validation — visible in the `Autoupdate` log as an EdDSA
rejection. That is 1.2.1, 1.2.2 and 1.4.0: no user has ever been able to
self-update.

Five independent evidence lines: the Sparkle source above; every fixture
shipped with Sparkle; `sign_update --help`, which prints the pair ready to
paste as enclosure attributes; the runtime rejection log; and all three
published signatures verifying valid against their own ZIPs — the signatures
were correct all along, only misplaced.

## Two hypotheses that were wrong, and how they were caught

**"`NSButton.acceptsFirstMouse` is false, so the first click on an inactive
app is swallowed."** Probed it directly instead of trusting the memory:

```
plain acceptsFirstMouse: true
rounded acceptsFirstMouse: true
```

`NSButton` takes click-through. The mechanism does not exist. The log evidence
proves the button was never *fired*; it never proved the button was *clicked*.

**"An activation-guard flag cannot latch, because Sparkle always ends the
session."** It can. `SPUStandardUserDriver.m:293-306`: when
`standardUserDriverShouldHandleShowingScheduledUpdate` returns `NO`, Sparkle
shows nothing and dispatches `standardUserDriverWillFinishUpdateSession` only
from `dismissUpdateInstallation` (`:908-914`) — which never arrives for a
deferred update. The 42-line guard would have latched permanently, disabling
`deactivate(withPolicy:)` and leaving a permanent Dock icon, a Cmd-Tab entry
and hidden app menus. It was reverted; the branch ships zero Swift changes.

The focus/burial observation survives as issue #32, labelled `needs-repro`.

## The gate that certified the bug

`docs/release-guide.md` had asked for:

```bash
curl -s …/appcast.xml | grep -c 'enclosure[^>]*sparkle:edSignature'
```

The template in the same document writes `<enclosure` across several lines, so
a line-based grep returns **0 on a perfectly correct feed** — the check could
never have caught this and would have failed the fix. Replaced with an
XML-aware gate, tested in both directions:

| feed | enclosure attrs | item children | items |
|---|---|---|---|
| corrected | 3 | 0 | 3 |
| broken (old shape) | 0 | 3 | 3 |

## Decision

- Republish rather than re-sign. The diff against the previously published feed
  is only the three signature moves; the signature bytes are byte-identical.
  Uploaded to release v1.4.0 with `--clobber`; verified 3/0/3 at the GitHub
  asset and again at `skein.ariadnev.com` after the Worker's 300 s cache
  expired.
- Ship the fix as docs only. No Swift change is justified by the proven cause.
- PR #31 says `Refs #30`, not `Fixes`. The feed being correct is not the same
  as an update installing; only a hardware self-update closes the issue.
- Issue #30 retitled to the proven cause and its body rewritten with a
  corrections section, since the original four claims were all wrong.

## Next steps

- Run 1.2.1 → 1.4.0 self-update on hardware against the republished feed. This
  closes #30 and the last open box in phase 1. Needs fresh maintainer consent —
  it touches `/Applications/Skein.app`.
- Replace the hand-authored Step 5 template with a wrapper around Sparkle's
  `generate_appcast`, which produces the correct shape by construction. A
  hand-edited XML template is what made this possible.
- Reproduce or close #32.
