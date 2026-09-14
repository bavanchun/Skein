# Upgrade from Frost to Skein

Skein is Frost's continuation under a new name and a new bundle identifier
(`com.ariadnev.Skein`). To macOS, that makes it a different app — permissions
and window layouts are keyed to the bundle ID and cannot be migrated
programmatically. Everything else (settings, hotkeys, menu bar layout,
appearance) is copied on Skein's first launch.

Follow the steps in order.

## 1. Download Skein

- Get `Skein-<version>.zip` from
  <https://github.com/bavanchun/Skein/releases/latest>. Take whatever
  the latest release offers; there is no reason to pin an older one.
- Double-click to unzip; you'll get `Skein.app`.

## 2. Move to /Applications

Drag `Skein.app` into `/Applications`. Skein and Frost can coexist — leave
`/Applications/Frost.app` alone for now. We'll remove it at the end after
confirming migration worked.

## 3. First launch (Gatekeeper)

Right-click `Skein.app` → **Open** → **Open** in the dialog. Only needed the
first time; after that a double-click works.

If macOS refuses with "cannot verify developer", open **System Settings →
Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to
the Skein message.

## 4. Grant permissions

macOS ties Accessibility and Screen Recording to the bundle ID, so Frost's
permissions do **not** transfer. Skein will prompt on first launch; if it
doesn't, add it manually:

- **System Settings → Privacy & Security → Accessibility** → toggle
  `Skein` on. If it's not in the list, click `+` and pick
  `/Applications/Skein.app`.
- **System Settings → Privacy & Security → Screen Recording** → same. Skein
  needs this to detect the menu bar layout.

After granting Screen Recording, macOS will ask you to quit and reopen
Skein. Do that.

## 5. Verify the migration

Open `Skein → Settings`. You should see:

- Your existing menu bar layout (hidden icons, always-hidden section, pinned
  items) — check the **Menu Bar Layout** tab.
- Your hotkeys — **Hotkeys** tab. The old `Enable Frost Bar` hotkey is now
  `Enable Skein Bar`; the key combination is preserved.
- Your appearance settings (colours, tint, shadow, split) — **Appearance**
  tab.
- Your "Show Skein Icon" / bar location / pinned location preferences —
  **General**.

If anything is missing, **stop here** and tell VChun before removing Frost —
the migration is a one-shot copy on first launch, and Frost's settings are
the only remaining source.

## 6. Quit Frost

Click the Frost icon in the menu bar → **Quit Frost**. Or:

```
osascript -e 'tell application "Frost" to quit'
```

## 7. Remove Frost.app (safe once step 5 passed)

You asked whether Frost needs to be removed completely. Short answer: **yes,
after step 5 passes**, because:

- Two menu bar managers running at once will fight over the same icons.
- Frost's `com.vchun.Frost` preferences on disk are now dead weight — Skein
  copied what it needed on first launch and won't read them again.

Remove the app:

```
sudo rm -rf /Applications/Frost.app
```

(If you installed Frost somewhere else, adjust the path.)

Optional — also delete Frost's preferences and Accessibility grant:

```
defaults delete com.vchun.Frost
tccutil reset Accessibility com.vchun.Frost
tccutil reset ScreenCapture com.vchun.Frost
```

Skein is unaffected by any of these — its bundle ID is
`com.ariadnev.Skein`, a completely separate domain.

## 8. Confirm autostart, then you're done

- **Skein → Settings → Advanced** → **Launch at Login**: toggle off then on to
  re-register with macOS as the Skein bundle ID (Frost's login-item entry, if
  you had one, points at a path that no longer exists).
- Restart your Mac once to confirm Skein comes back up cleanly.

Updates from now on flow through `skein.ariadnev.com/appcast.xml`; Sparkle
will offer them in-app. No manual re-download needed.
