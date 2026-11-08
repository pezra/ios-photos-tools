#!/bin/bash
# Test photos for the simulator.
#   photos.sh make [COUNT]   generate COUNT photos (default 300) into the work folder
#   photos.sh add            add them to the simulator's Photos library
#   photos.sh drive          copy them onto the test drive folder, in its year layout, as if a
#                            computer had put the library there already
source "$(dirname "$0")/env.sh"

fixtures="$WORK_DIR/fixtures"
case "${1:-}" in
make)
    rm -rf "$fixtures"
    python3 "$(dirname "$0")/make-fixtures.py" "$fixtures" "${2:-300}"
    ;;
add)
    udid=$(boot_sim)
    find "$fixtures" -name '*.JPG' -print0 | xargs -0 -n 200 xcrun simctl addmedia "$udid"
    echo "Added $(find "$fixtures" -name '*.JPG' | wc -l | tr -d ' ') photos to $SIM_NAME."
    ;;
drive)
    drive="$(data_container)/Documents/$DRIVE_FOLDER"
    mkdir -p "$drive"
    cp -R "$fixtures"/. "$drive"/
    echo "Copied the fixtures to $drive"
    ;;
*)
    echo "usage: photos.sh make [COUNT] | add | drive" >&2
    exit 2
    ;;
esac
