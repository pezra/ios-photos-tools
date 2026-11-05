#!/bin/bash
# Keeps the app from expiring on the phone. Apps signed with a free Apple account stop opening after
# 7 days, so this rebuilds the latest commit on main with a fresh profile and reinstalls it, which
# keeps the app's data. It does nothing unless less than 3 days are left, so it's cheap to run often.
#
#   renew-phone-app.sh            renew if due
#   renew-phone-app.sh --force    renew now
#   renew-phone-app.sh --dry-run  build and report the expiry date, without installing
#
# Only committed code reaches the phone: it builds an export of main, not the working tree.
set -euo pipefail

BUNDLE_ID="org.barelyenough.ios-photos-tools"
DEVICE_ID="AC400572-81A9-5D01-8571-EA624BC2A6C4"
RENEW_WITHIN_SECONDS=$((3 * 24 * 60 * 60))

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/Library/Application Support/ios-photos-tools-renewal"
WORK_DIR="$HOME/Library/Caches/ios-photos-tools-renewal"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
EXPIRY_FILE="$STATE_DIR/installed-expiry"

MODE="${1:-}"
mkdir -p "$STATE_DIR" "$WORK_DIR"

log() { echo "$(date '+%F %T') $*"; }

notify() {
    osascript -e "display notification \"$1\" with title \"Photos Tools renewal\"" >/dev/null 2>&1 || true
}

# Only one run at a time. launchd can start one while a slow build is still going.
LOCK="$STATE_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    log "Another run is in progress."
    exit 0
fi
trap 'rmdir "$LOCK"' EXIT

now=$(date +%s)
installed_expiry=$(cat "$EXPIRY_FILE" 2>/dev/null || echo 0)
remaining=$((installed_expiry - now))

if [[ -z "$MODE" && $remaining -gt $RENEW_WITHIN_SECONDS ]]; then
    exit 0
fi

# Failing early is normal, since it's tried again in a few hours. Only say so once it's urgent.
notify_if_urgent() {
    if [[ $remaining -lt $((24 * 60 * 60)) ]]; then
        notify "$1 The app expires soon."
    fi
}

fail() {
    log "FAILED: $1"
    notify_if_urgent "$1"
    exit 1
}

if [[ "$MODE" != "--dry-run" ]]; then
    xcrun devicectl device info details --device "$DEVICE_ID" >/dev/null 2>&1 || {
        log "Phone not reachable; will try again."
        notify_if_urgent "Connect your phone to this Mac."
        exit 0
    }
fi

commit=$(git -C "$REPO" rev-parse --short refs/heads/main)
log "Building main ($commit)"
SOURCE="$WORK_DIR/source"
rm -rf "$SOURCE"
mkdir -p "$SOURCE"
git -C "$REPO" archive refs/heads/main | tar -x -C "$SOURCE"

APP="$WORK_DIR/DerivedData/Build/Products/Debug-iphoneos/IOSPhotosTools.app"

build() {
    xcodebuild -project "$SOURCE/IOSPhotosTools.xcodeproj" -scheme IOSPhotosTools \
        -destination 'generic/platform=iOS' -derivedDataPath "$WORK_DIR/DerivedData" \
        -allowProvisioningUpdates build >"$WORK_DIR/build.log" 2>&1
}

built_expiry() {
    local iso
    iso=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - -)
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s
}

build || fail "The build failed; see $WORK_DIR/build.log."
expiry=$(built_expiry) || fail "Couldn't read the built app's expiry date."

# Xcode can reuse a profile that's still valid, and installing that wouldn't buy any time. Setting
# the local copy aside makes it fetch a new one. It's put back if that doesn't work.
if [[ $((expiry - now)) -lt $RENEW_WITHIN_SECONDS ]]; then
    log "Xcode reused a profile that expires soon; asking for a new one."
    ASIDE="$WORK_DIR/profiles-aside"
    rm -rf "$ASIDE"
    mkdir -p "$ASIDE"
    for profile in "$PROFILES_DIR"/*; do
        [[ -f "$profile" ]] || continue
        identifier=$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
        if [[ "$identifier" == *".$BUNDLE_ID" ]]; then
            mv "$profile" "$ASIDE/"
        fi
    done
    if ! build || ! expiry=$(built_expiry); then
        mv "$ASIDE"/* "$PROFILES_DIR/" 2>/dev/null || true
        fail "Couldn't get a new profile. Is your Apple account still signed in to Xcode?"
    fi
    if [[ $((expiry - now)) -lt $RENEW_WITHIN_SECONDS ]]; then
        fail "Apple gave back a profile that still expires soon."
    fi
fi

expiry_text=$(date -r "$expiry" '+%F %H:%M')
if [[ "$MODE" == "--dry-run" ]]; then
    log "Dry run: built $commit, signed until $expiry_text. Not installed."
    exit 0
fi

xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >"$WORK_DIR/install.log" 2>&1 \
    || fail "Installing failed; see $WORK_DIR/install.log."
echo "$expiry" >"$EXPIRY_FILE"
log "Installed $commit, signed until $expiry_text."
