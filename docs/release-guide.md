# Skein Release Guide

Personal-build release workflow for the `bavanchun/Skein` fork. Targets macOS 14+, signed with a free Personal Apple Developer account (no notarization, runs locally only).

This document owns release mechanics. The surrounding process rules — branching, pull requests, and the version approval gate — live in [`DEVELOPMENT_WORKFLOW.md`](DEVELOPMENT_WORKFLOW.md).

## One-Time Setup

### 1. Sparkle Ed25519 keypair

Sparkle auto-updates require an EdDSA keypair. Private key lives in the macOS Keychain; public key is embedded in `Skein/Info.plist` as `SUPublicEDKey`.

```bash
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData/Skein-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys)

# Generate keys (auto-stored in Keychain); prints the public key + Info.plist snippet
"$SIGN_UPDATE"

# Backup the private key to a file OUTSIDE the repo (in case of Keychain loss)
"$SIGN_UPDATE" -x ~/.config/skein/sparkle-private-ed25519-key
chmod 600 ~/.config/skein/sparkle-private-ed25519-key

# Re-lookup the public key later (for verifying Info.plist)
"$SIGN_UPDATE" -p
```

Copy the printed public key (base64, 44 chars) into `Skein/Info.plist` → `SUPublicEDKey`. Never commit the private key.

### 2. Signing approach: unsigned build + manual codesign

**`xcodebuild archive` does not work with a free Personal Team on Xcode 26.6** — it requires a "Mac Development" certificate distinct from the "Apple Development" cert Xcode issues by default, and Personal (free) accounts cannot provision one. Both automatic (`CODE_SIGN_STYLE=Automatic`) and manual (`CODE_SIGN_STYLE=Manual` + explicit `CODE_SIGN_IDENTITY`) archive attempts fail — see [Troubleshooting](#troubleshooting) for the exact errors hit.

**What actually works:** build unsigned with `xcodebuild build` (not `archive`), then manually `codesign` every nested bundle inside-out with the "Apple Development" identity already in Keychain. This is Step 3 below — do not try `xcodebuild archive` first, it wastes a round-trip.

### 3. GitHub CLI auth

```bash
gh auth login   # choose github.com, account bavanchun, scope: repo
gh auth status  # confirm active account is bavanchun
```

### 4. Update feed worker

Sparkle reads `SUFeedURL` from a value compiled into every shipped binary, so a
repository URL there means renaming or moving the repository silently cuts off
updates for everything already installed. That is what happened to Frost.

`skein.ariadnev.com` is a Cloudflare Worker that owns the address and proxies
GitHub Releases, so the backing store can move without stranding anyone. Source
lives in [`infra/appcast-worker/`](../infra/appcast-worker/).

```bash
cd infra/appcast-worker
wrangler deploy
curl -s https://skein.ariadnev.com/health          # -> ok
```

It is deliberately its own worker on its own hostname rather than a route inside
`ariadnev-edge`, which serves `ariadnev.com` and the CLI install script. An
update feed has no business sharing that blast radius.

A `404` from `/appcast.xml` means no release is published yet; Sparkle reads
that as "no update available", which is correct.

### 5. SSH tag signing

Release tags are signed with the maintainer's SSH key rather than GPG. Configured per-repo:

```bash
git config --local gpg.format ssh
git config --local user.signingkey ~/.ssh/id_ed25519.pub
git config --local tag.gpgsign true
```

The same public key must be registered on GitHub as a **signing** key (separate from the authentication key) for the "Verified" badge to appear:

```bash
gh auth refresh -h github.com -s admin:ssh_signing_key
gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "Skein tag signing"
```

Verify signing works before a release: `git tag -s _sigtest -m t && git cat-file -p _sigtest | grep "SSH SIGNATURE" && git tag -d _sigtest`.

## Versioning Policy

`MARKETING_VERSION` follows semantic versioning, tagged as `vMAJOR.MINOR.PATCH`.

| Bump | For | Example |
|---|---|---|
| PATCH | Bug fixes, refactoring, performance, docs, dependency updates, security fixes, tests, CI/CD — anything with no new user-facing feature | `v1.0.0` → `v1.0.1` |
| MINOR | New features, commands, APIs, or UI components, all backward compatible | `v1.0.0` → `v1.1.0` |
| MAJOR | Breaking changes: removed features, incompatible configuration, API changes, schema changes needing migration | `v1.0.0` → `v2.0.0` |

Never bump MINOR or MAJOR for README edits, comments, formatting, refactoring alone, dependency updates, bug fixes, tests, or CI/CD. Those are always PATCH.

When the correct bump is unclear, prefer PATCH over MINOR, and MINOR over MAJOR. Under-bumping is recoverable; an inflated version number is permanent once tagged.

**Tags are never cut automatically.** Choosing the version is the maintainer's call — propose the number, get explicit approval, then tag (Step 6). This applies to automated tooling and AI collaborators.

`CURRENT_PROJECT_VERSION` is a separate monotonic build counter, not part of this policy: it increments on every release regardless of bump size, because Sparkle orders updates by it.

## Per-Release Flow

### Step 1 — Bump version (if needed)

Pick the new version per the Versioning Policy above, then edit `Skein.xcodeproj/project.pbxproj`:

```
MARKETING_VERSION = <new.version>;       # e.g., 1.3.0
CURRENT_PROJECT_VERSION = <build-num>;   # e.g., 1130
```

Both Debug and Release configs must match. Bump build number for every release, even tiny changes.

### Step 2 — Verify identity settings

Confirm before each release:

```bash
grep -E "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|NSHumanReadableCopyright" Skein.xcodeproj/project.pbxproj | sort -u
```

Expected:
- `PRODUCT_BUNDLE_IDENTIFIER = com.ariadnev.Skein;`
- `DEVELOPMENT_TEAM = LC6N3KUML9;`
- `INFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © <year> VChun";`

### Step 3 — Resolve deps, build unsigned, codesign manually

```bash
# Refresh SPM deps (only if Package.resolved changed)
xcodebuild -resolvePackageDependencies -scheme Skein -project Skein.xcodeproj

# Clean + build UNSIGNED (output dir avoids the literal word 'build' which trips some hooks)
rm -rf .release-output/
xcodebuild build \
  -scheme Skein \
  -project Skein.xcodeproj \
  -configuration Release \
  -derivedDataPath .release-output/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

# Copy to a clean path for signing
APP_PATH=$(find .release-output -name "Skein.app" -type d | head -1)
mkdir -p .release-output/sign
cp -R "$APP_PATH" .release-output/sign/Skein.app
```

Now codesign every nested bundle **inside-out** — XPC services and helper apps first, then the enclosing framework, then the main app last:

```bash
APP=".release-output/sign/Skein.app"
CERT=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

# 1. XPC services (innermost)
codesign --force --options runtime --sign "$CERT" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$CERT" "$SPARKLE/XPCServices/Installer.xpc"

# 2. Skein's own XPC service (also innermost)
codesign --force --options runtime --sign "$CERT" "$APP/Contents/XPCServices/MenuBarItemService.xpc"

# 3. Sparkle's nested helpers. Autoupdate is a bare Mach-O, not a bundle, and
#    arrives ad-hoc signed from Sparkle's binary artifact — sign it explicitly or
#    the shipped app carries a helper with no team identifier.
codesign --force --options runtime --sign "$CERT" "$SPARKLE/Autoupdate"
codesign --force --options runtime --sign "$CERT" "$SPARKLE/Updater.app"

# 4. Sparkle.framework itself
codesign --force --options runtime --sign "$CERT" "$APP/Contents/Frameworks/Sparkle.framework"

# 5. Main app, with entitlements, last
codesign --force --options runtime \
  --entitlements Skein/Skein.entitlements \
  --sign "$CERT" "$APP"

# Verify
codesign --verify --verbose=4 "$APP"
codesign -dv --verbose=4 "$APP"

# No nested binary may still be ad-hoc: every hit must name the Apple Development
# identity, not "Signature=adhoc".
for b in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" \
         "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
         "$APP/Contents/XPCServices/MenuBarItemService.xpc"; do
  echo "== $b"; codesign -dv "$b" 2>&1 | grep -E "Signature|TeamIdentifier"
done
```

Expected: `Authority=Apple Development: <apple-id> (<TEAM_ID>)` chained to WWDR + Apple Root CA, `flags=0x10000(runtime)` (Hardened Runtime), `Identifier=com.ariadnev.Skein`. `codesign --verify` must print `valid on disk` + `satisfies its Designated Requirement`.

If any nested bundle is missing from `Contents/Frameworks/`, re-run `find "$APP" -name "*.app" -o -name "*.xpc" -o -name "*.framework"` and sign every hit before the main app.

### Step 4 — Zip, sign zip, generate appcast

```bash
VERSION=1.3.0
BUILD=1130

# Zip preserving .app bundle structure (ditto -k preserves resource forks/signature)
cd .release-output/sign
ditto -c -k --keepParent Skein.app "../Skein-${VERSION}.zip"
cd ../..

# Sign the zip with Sparkle private key (auto-read from Keychain)
# Step 3 built into .release-output/DerivedData, so Sparkle's tools are there too,
# not under ~/Library/Developer/Xcode/DerivedData.
SIGN_UPDATE=.release-output/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
"$SIGN_UPDATE" ".release-output/Skein-${VERSION}.zip"
# Output: sparkle:edSignature="<sig>" length="<bytes>"
```

### Step 4b — Build the DMG (optional, secondary)

The ZIP from Step 4 is the download to advertise. The DMG is an extra, and on
current macOS it is the *worse* of the two — see the box below before pointing
anything at it.

```bash
Scripts/make-dmg.sh .release-output/sign/Skein.app
# → .release-output/Skein-<version>.dmg, plus its size and sha256
```

The script stages `Skein.app` beside an `/Applications` symlink so the volume
opens with something to drag into, names the volume `Skein <version>`, writes a
compressed read-only image (`UDZO`), and codesigns the image.

**Do not point the appcast enclosure at the DMG.** Sparkle would have to mount a
volume on every update instead of unpacking an archive, for no gain. Step 5's
enclosure keeps referencing the ZIP.

Verify before uploading:

```bash
hdiutil attach .release-output/Skein-<version>.dmg -nobrowse -readonly
codesign --verify --verbose=2 "/Volumes/Skein <version>/Skein.app"
hdiutil detach "/Volumes/Skein <version>"
```

> **Why the ZIP is the recommended download, not the DMG.**
> Until Skein is notarized, macOS quarantines either download and refuses the
> first open. The two formats fail *differently*:
>
> | | ZIP | DMG |
> |---|---|---|
> | Opening the download | works; you get `Skein.app` | blocked outright |
> | The block dialog | right-click the app → **Open** offers a real Open button | offers only **Move to Trash** / **Done** |
> | Escape without Terminal | right-click → Open | System Settings → Privacy & Security → **Open Anyway** |
>
> A DMG looks more polished and is measurably harder to get past. Test this by
> downloading through a browser — a locally built file carries no
> `com.apple.quarantine` attribute, so the problem never appears.

### Step 5 — Write `appcast.xml`

`sign_update` prints the pair ready to paste — `sparkle:edSignature="…"
length="…"`. Both are **attributes of `<enclosure>`**. Sparkle reads the
signature from the enclosure's attributes and nowhere else, so a
`<sparkle:edSignature>` element written as a child of `<item>` is silently
ignored and the update is rejected at install time with *"The app has an EdDSA
public key, but there is no EdDSA signature in the update"*.

```xml
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Skein</title>
    <link>https://github.com/bavanchun/Skein/releases</link>
    <description>Personal fork of Ice</description>
    <language>en</language>
    <item>
      <title>${VERSION}</title>
      <pubDate>Mon, 27 Jul 2026 00:00:00 +0000</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <enclosure
        url="https://github.com/bavanchun/Skein/releases/download/v${VERSION}/Skein-${VERSION}.zip"
        sparkle:os="macos"
        sparkle:edSignature="INSERT_SIGNATURE_HERE"
        length="INSERT_LENGTH_HERE"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

For subsequent releases, **append** a new `<item>` above the previous one. Sparkle picks the highest `sparkle:version` it can install.

### Step 6 — Push tag, create GitHub release

Confirm the version was approved (see Versioning Policy) before running this — pushing a tag is the point of no return.

```bash
git tag -s v${VERSION} -m "Skein ${VERSION}"
git push origin v${VERSION}

gh release create v${VERSION} \
  ".release-output/Skein-${VERSION}.zip" \
  ".release-output/appcast.xml" \
  --repo bavanchun/Skein \
  --title "${VERSION}" \
  --notes "Personal build of Skein ${VERSION} (build ${BUILD})."
```

**Both assets must upload to the same release.** Sparkle fetches `https://skein.ariadnev.com/appcast.xml`, which the worker proxies to `releases/latest/download/appcast.xml` (GitHub redirects to the latest release's `appcast.xml`), which then points at the same release's `Skein-${VERSION}.zip`.

### Step 7 — Install locally

```bash
rm -rf /Applications/Skein.app
cp -R .release-output/sign/Skein.app /Applications/

# Clear quarantine (Personal Team signing — Gatekeeper may warn)
xattr -cr /Applications/Skein.app

open /Applications/Skein.app
```

On first launch: grant Accessibility (required) and ScreenRecording (optional, for Skein Bar + appearance editor) permissions. Verify the process is alive and using the fork's own UserDefaults domain:

```bash
pgrep -fl "Skein.app/Contents/MacOS/Skein"
defaults read com.ariadnev.Skein SUHasLaunchedBefore   # 1 once Sparkle has initialized
```

## Troubleshooting

### `No Account for Team "LC6N3KUML9"` (archive)

Happens with `xcodebuild archive` + automatic signing. Adding the Apple ID in **Xcode → Settings → Accounts** does not fix this on a free Personal Team — see the next error.

### `No signing certificate "Mac Development" found` (archive, any signing style)

This is the actual blocker on Xcode 26.6 with a free Personal Team, confirmed by testing all three: automatic signing, manual signing with plain `CODE_SIGN_IDENTITY=Apple Development`, and manual signing with an SDK-scoped override (`CODE_SIGN_IDENTITY[sdk=macosx*]`). All three fail archive — Xcode's archive action insists on a "Mac Development" cert that free accounts cannot obtain. **Do not keep retrying archive flags.** Switch to `xcodebuild build` (unsigned) + manual `codesign`, as in Step 3.

### `xattr` quarantine warning persists

```bash
xattr -dr com.apple.quarantine /Applications/Skein.app
```

### Sparkle "No updates available" but release is published

- Confirm `appcast.xml` is attached to the **latest** GitHub release (not an older one).
- Confirm `SUFeedURL` in `Skein/Info.plist` is `https://skein.ariadnev.com/appcast.xml`.
- Confirm `SUPublicEDKey` matches the Keychain's public key (`generate_keys -p`).
- Confirm `sparkle:edSignature` was generated with the matching private key.
- The shipped `sparkle:version` must be strictly greater than the installed build's `CFBundleVersion`.

### Personal Team cert rotated

Free Personal Team certs can expire. Check:

```bash
security find-identity -v -p codesigning
```

If missing, regenerate through Xcode Accounts → team → "Manage Certificates" → + → Apple Development.

## Future-Release Checklist

- [ ] Choose the bump per the Versioning Policy and get the version explicitly approved
- [ ] Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `Skein.xcodeproj/project.pbxproj` (Debug + Release)
- [ ] Commit changes on `main`
- [ ] `xcodebuild build` (unsigned) → `.release-output/sign/Skein.app`
- [ ] `codesign` inside-out (Sparkle's XPC services → `Contents/XPCServices/MenuBarItemService.xpc` → Autoupdate → Updater.app → Sparkle.framework → main app)
- [ ] `codesign --verify --verbose=4` confirms "valid on disk"; no nested binary reports `Signature=adhoc`
- [ ] `ditto` zip + `sign_update` for EdDSA signature
- [ ] Update `appcast.xml` (append `<item>`, bump `pubDate`) with `sparkle:edSignature` as an **enclosure attribute**
- [ ] `git tag -s v<x.y.z>` (SSH-signed) + `git push origin v<x.y.z>`
- [ ] `gh release create v<x.y.z> Skein-<x.y.z>.zip appcast.xml`
- [ ] Verify `curl -s https://skein.ariadnev.com/appcast.xml` returns the new appcast
- [ ] Install locally, confirm process is running (`pgrep -fl Skein.app`) and `defaults read com.ariadnev.Skein` shows fork-owned keys
- [ ] Settings → About → Check for Updates reports current version

## Pitfalls

- **`sparkle:edSignature` goes on the `<enclosure>`, never inside `<item>`.**
  Sparkle reads it from the enclosure's attribute dictionary only. Put it
  anywhere else and the feed still parses, the update still downloads, extracts
  and starts installing — then dies at validation with *"there is no EdDSA
  signature in the update, so the update will be rejected."* Gate the file
  before uploading it, and gate the live feed afterwards. The check must be
  XML-aware: the template above writes `<enclosure` across several lines, so a
  line-based `grep` reports zero hits on a perfectly correct feed.
  ```bash
  gate() {  # every item signed on the enclosure, none inside <item>
    local f=$1
    echo "enclosure attrs: $(xmllint --xpath 'count(//item/enclosure/@*[local-name()="edSignature"])' "$f")"
    echo "item children:   $(xmllint --xpath 'count(//item/*[local-name()="edSignature"])' "$f")"
    echo "items:           $(xmllint --xpath 'count(//item)' "$f")"
  }
  gate appcast.xml                     # before: attrs == items, children == 0
  curl -s https://skein.ariadnev.com/appcast.xml -o /tmp/live.xml && gate /tmp/live.xml
  ```
  The Worker caches the feed for 300 s (`infra/appcast-worker/index.js`), so
  wait out that window before believing a live-feed result.
- **Appcast must be on the latest release.** GitHub's `releases/latest/download/<file>` only resolves assets on the most recent published release.
- **Bundle ID conflict.** If upstream `com.jordanbaird.Ice` is also installed, both apps share UserDefaults + keychain. Fork uses `com.ariadnev.Skein` to avoid this — do not revert.
- **Private key safety.** `~/.config/skein/sparkle-private-ed25519-key` is the only offline backup of the Sparkle signing key. If lost, all future updates require shipping a new `SUPublicEDKey` (forces a manual reinstall, breaking auto-update).
- **Personal Team signing, not distribution signing.** The `Apple Development` cert is not `Developer ID Application`, so the build is not notarized and Gatekeeper blocks the first launch on another Mac until the user right-clicks → Open or clears quarantine. The app embeds no provisioning profile, so it is not limited to registered devices. Notarization requires a paid Apple Developer Program membership.
- **Upstream Ice is notarized; Skein is not.** `Ice.app` from `jordanbaird/Ice` carries `Developer ID Application: Jordan Baird (K2ATHQPJDP)`, `spctl` reports `source=Notarized Developer ID`, and `stapler validate` passes. Ice ships a ZIP and no DMG — not to dodge Gatekeeper, which it does not need to dodge, but because a ZIP is simpler and is what Sparkle consumes. The gap between Skein's download experience and Ice's is notarization, not packaging.
- **`xcodebuild archive` cannot sign this app on a free Personal Team.** Confirmed across automatic and manual signing styles on Xcode 26.6 — always falls back to `xcodebuild build` (unsigned) + manual `codesign`. Do not spend time retrying archive-based signing flags on a fresh Personal Team; go straight to the unsigned-build path.
- **Sign nested bundles before the outer one.** `codesign` on `Skein.app` alone does not re-sign `Sparkle.framework`'s nested `Updater.app`/`Downloader.xpc`/`Installer.xpc`, nor Skein's own `Contents/XPCServices/MenuBarItemService.xpc` — each needs its own `codesign` call, innermost first, or the outer signature's sealed resources will mismatch and `codesign --verify` fails.
