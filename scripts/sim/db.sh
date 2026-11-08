#!/bin/bash
# Runs sqlite3 on the app's backup database in the simulator.
#   db.sh "SELECT count(*) FROM assets"
#   db.sh            an interactive shell
#   db.sh --copy DIR copy the database (with its WAL) to DIR, as a backup before a migration
source "$(dirname "$0")/env.sh"

db="$(data_container)/Library/Application Support/backup.sqlite"
if [[ "${1:-}" == "--copy" ]]; then
    mkdir -p "$2"
    cp "$db"* "$2/"
    echo "Copied to $2"
else
    sqlite3 "$db" "$@"
fi
