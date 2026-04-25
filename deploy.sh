#!/usr/bin/env bash
set -e

PI="theremerin@192.168.1.90"
REMOTE_DIR="~/theremin"

# Stage and commit any dirty changes
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Uncommitted changes — commit before deploying." >&2
  exit 1
fi

# Push to GitHub
git push origin master

# Pull, build, and restart service on Pi
ssh "$PI" "cd $REMOTE_DIR && git checkout master && git pull && rm -f *.o umts && make ultra && sudo systemctl restart mts"

echo "Deployed."
