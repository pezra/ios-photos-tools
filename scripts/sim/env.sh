# Shared settings for the simulator scripts. Sourced, not run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_ID="org.barelyenough.ios-photos-tools"
SIM_NAME="${SIM_NAME:-iPhone 17}"
WORK_DIR="$HOME/Library/Caches/ios-photos-tools-sim"
DERIVED_DATA="$WORK_DIR/DerivedData"
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/IOSPhotosTools.app"

# The local S3 service that stands in for the bucket: Moto, a mock of S3, in Docker. It accepts any
# credentials, and supports versioning and conditional writes.
S3_IMAGE="motoserver/moto:latest"
S3_PORT="${S3_PORT:-9000}"
# A second service on another port (S3_PORT=9001 s3.sh up) gets its own container.
S3_CONTAINER="pt-s3"; [[ "$S3_PORT" == 9000 ]] || S3_CONTAINER="pt-s3-$S3_PORT"
S3_URL="http://127.0.0.1:$S3_PORT"
S3_KEY="ptadmin"
S3_SECRET="ptadmin-secret"
DRIVE_FOLDER="TestDrive"

mkdir -p "$WORK_DIR"

sim_udid() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d["isAvailable"]:
            print(d["udid"]); sys.exit(0)
sys.exit("No available simulator named " + name)' "$SIM_NAME"
}

boot_sim() {
    local udid
    udid=$(sim_udid)
    xcrun simctl bootstatus "$udid" -b >/dev/null
    echo "$udid"
}

data_container() {
    xcrun simctl get_app_container "$(sim_udid)" "$BUNDLE_ID" data
}
