#!/bin/bash
# Build, sign, install and open the isolated development app. Release stays intact.
# Usage: Scripts/run-dev.sh [--build-only]
set -euo pipefail

skein_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-}"
if [[ $# -gt 1 || ( -n "$mode" && "$mode" != "--build-only" ) ]]; then
    echo 'Usage: Scripts/run-dev.sh [--build-only]' >&2
    exit 2
fi

output="$skein_root/.ci-output/dev"
derived="$skein_root/.ci-output/dev-build"
destination='/Applications/Skein Dev.app'
dev_id='com.ariadnev.Skein.dev'
mkdir -p "$output"

identity="${SKEIN_DEV_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/Apple Development:/ {print $2; exit}')"
fi
if [[ -z "$identity" ]]; then
    echo 'An Apple Development signing identity is required for same-team XPC. Add one in Xcode Accounts.' >&2
    exit 1
fi

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"
}

require_dev_bundle() {
    [[ "$(bundle_id "$1")" == "$dev_id" ]] || {
        echo "Refusing to replace a non-development bundle: $1" >&2
        exit 1
    }
}

# A deterministic DerivedData directory makes subsequent rebuilds incremental.
xcodebuild build -project "$skein_root/Skein.xcodeproj" -scheme 'Skein Dev' \
    -configuration Debug -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

built_app="$derived/Build/Products/Debug/Skein Dev.app"
require_dev_bundle "$built_app"
stage="$(mktemp -d "$output/sign.XXXXXX")"
install_stage=''
cleanup() {
    if [[ -n "$install_stage" ]]; then
        if [[ -d "$install_stage/previous.app" && ! -e "$destination" ]]; then
            mv "$install_stage/previous.app" "$destination"
        fi
        rm -rf "$install_stage"
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
ditto "$built_app" "$stage/Skein Dev.app"
signed_app="$stage/Skein Dev.app"
sparkle="$signed_app/Contents/Frameworks/Sparkle.framework/Versions/B"

# Xcode's Debug executable loads its implementation from a separate dylib.
# Ad-hoc linker signatures pass verification but fail runtime team validation.
for library in "$signed_app"/Contents/MacOS/*.dylib; do
    [[ -f "$library" ]] || continue
    codesign --force --options runtime --sign "$identity" "$library"
done

# Sign nested code first, using the same identity on both ends of the XPC link.
for nested in \
    "$sparkle/XPCServices/Downloader.xpc" \
    "$sparkle/XPCServices/Installer.xpc" \
    "$signed_app/Contents/XPCServices/MenuBarItemService.xpc" \
    "$sparkle/Updater.app" \
    "$signed_app/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --sign "$identity" "$nested"
done
codesign --force --options runtime --entitlements "$skein_root/Skein/SkeinDev.entitlements" \
    --sign "$identity" "$signed_app"
codesign --verify --deep --strict "$signed_app"

if [[ -e "$output/Skein Dev.app" ]]; then
    require_dev_bundle "$output/Skein Dev.app"
    rm -rf "$output/Skein Dev.app"
fi
mv "$signed_app" "$output/Skein Dev.app"
signed_app="$output/Skein Dev.app"
if [[ "$mode" == '--build-only' ]]; then
    echo "Signed development build: $signed_app"
    exit 0
fi

if [[ -e "$destination" ]]; then
    require_dev_bundle "$destination"
fi
# Only stop the installed development binary. An Xcode-run copy must be quit by
# its owner so this command cannot detach someone else's debugging session.
for pid in $(pgrep -x 'Skein Dev' || true); do
    executable="$(ps -p "$pid" -o comm=)"
    if [[ "$executable" != "$destination/Contents/MacOS/Skein Dev" ]]; then
        echo 'Quit the other running Skein Dev copy before installing.' >&2
        exit 1
    fi
    kill -TERM "$pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo 'Skein Dev did not quit; the installed bundle was not replaced.' >&2
        exit 1
    fi
done

# Stage on the destination volume and keep the previous dev app until the swap
# succeeds. The release path is never a replacement or cleanup target.
install_stage="$(mktemp -d /Applications/.skein-dev-install.XXXXXX)"
ditto "$signed_app" "$install_stage/Skein Dev.app"
codesign --verify --deep --strict "$install_stage/Skein Dev.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$install_stage/previous.app"
fi
mv "$install_stage/Skein Dev.app" "$destination"
echo "Installed: $destination"

if pgrep -x Skein >/dev/null; then
    echo 'Quit Skein Release, then open Skein Dev. Both manage the same menu bar.'
else
    open "$destination"
fi
