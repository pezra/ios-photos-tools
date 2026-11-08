#!/bin/bash
# Launches the app with the test bucket and drive folder set up, through the debug-only TestHooks.
#   launch.sh [bucket]        bucket "pt-a" (default) or "pt-b" on the local S3 service
#   NO_DRIVE=1 launch.sh      without setting the drive folder
#   EXTRA='"syncEnabled":true' launch.sh   extra settings, as JSON members, in place of the default
#                             "autoBackup":true,"driveAutoBackup":true (the app does nothing on its own without them)
source "$(dirname "$0")/env.sh"

udid=$(boot_sim)
bucket="${1:-pt-a}"
EXTRA="${EXTRA:-\"autoBackup\":true,\"driveAutoBackup\":true}"
settings="{\"endpoint\":\"$S3_URL\",\"region\":\"us-east-1\",\"bucket\":\"$bucket\",\"prefix\":\"photos\",\"usePathStyle\":true,\"accessKeyID\":\"$S3_KEY\",\"secretAccessKey\":\"$S3_SECRET\"${EXTRA:+,$EXTRA}}"
xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ -n "${NO_DRIVE:-}" ]]; then
    SIMCTL_CHILD_PT_TEST_SETTINGS="$settings" xcrun simctl launch "$udid" "$BUNDLE_ID"
else
    SIMCTL_CHILD_PT_TEST_SETTINGS="$settings" SIMCTL_CHILD_PT_TEST_DRIVE="$DRIVE_FOLDER" \
        xcrun simctl launch "$udid" "$BUNDLE_ID"
fi
