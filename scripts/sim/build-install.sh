#!/bin/bash
# Builds the app for the simulator and installs it, keeping its data.
#   build-install.sh          build the working tree
#   build-install.sh --clean  also delete the app and its data first
source "$(dirname "$0")/env.sh"

udid=$(boot_sim)
if [[ "${1:-}" == "--clean" ]]; then
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" || true
fi
xcodebuild -project "$REPO/IOSPhotosTools.xcodeproj" -scheme IOSPhotosTools \
    -destination "id=$udid" -derivedDataPath "$DERIVED_DATA" build >"$WORK_DIR/build.log" 2>&1 \
    || { tail -20 "$WORK_DIR/build.log"; echo "Build failed; see $WORK_DIR/build.log"; exit 1; }
xcrun simctl install "$udid" "$APP"
# No `simctl privacy grant photos`: on this simulator it leaves access undecided, replacing a grant
# made by tapping "Allow Full Access", which lasts until the app is uninstalled.
echo "Installed on $SIM_NAME ($udid)."
