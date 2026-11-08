#!/bin/bash
# Streams the app's log from the simulator.
#   logs.sh                 info and above
#   logs.sh listing pass    only these categories
#   LEVEL=debug logs.sh     include each pass's steps
source "$(dirname "$0")/env.sh"

predicate="subsystem == \"$BUNDLE_ID\""
if [[ $# -gt 0 ]]; then
    categories=$(printf '"%s",' "$@")
    predicate="$predicate AND category IN {${categories%,}}"
fi
xcrun simctl spawn "$(sim_udid)" log stream --style compact --level "${LEVEL:-info}" --predicate "$predicate"
