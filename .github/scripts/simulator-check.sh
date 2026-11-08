#!/bin/bash
# Runs a simulator build of ChaosPad.app in a fresh iPhone simulator for a few minutes and keeps screenshots, the app's
# log.txt and a sample of its threads in OUT_DIR. With DISC_DIR set (a folder holding the decrypted sc3.sparse), the disc
# image is put into the app's Documents folder, so the game boots as far as it gets without input (the logos, the main
# menu); without it only the start-up, the Metal device and the shaders are checked.
#
# Usage: simulator-check.sh ChaosPad.app OUT_DIR
# Environment: CHAOSPAD_BUNDLE_ID, DISC_DIR (optional)
set -euo pipefail

app=$1
mkdir -p "$2"
out=$(cd "$2" && pwd)
bundle=${CHAOSPAD_BUNDLE_ID:-com.lasmith1689.chaospad}

runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x.get("platform") == "iOS"]
print(r[-1]["identifier"] if r else "")')
devtype=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
d = [x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone") and "Pro" in x["name"]]
print(d[-1] if d else "")')
[ -n "$runtime" ] && [ -n "$devtype" ] || { echo "::error::no iOS simulator runtime/device type"; exit 1; }
echo "▶ Simulator: $devtype on $runtime"
udid=$(xcrun simctl create chaospad-check "$devtype" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl install "$udid" "$app"
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
mkdir -p "$data/Documents"
if [ -n "${DISC_DIR:-}" ] && [ -f "$DISC_DIR/sc3.sparse" ]; then
  mv "$DISC_DIR/sc3.sparse" "$data/Documents/sc3.sparse"
  echo "▶ the disc image is in the app's Documents ($(du -h "$data/Documents/sc3.sparse" | cut -f1))"
fi
echo "▶ Launching $bundle"
xcrun simctl launch "$udid" "$bundle"
elapsed=0
for wait in 20 40 60 60 60; do
  sleep "$wait"
  elapsed=$((elapsed + wait))
  xcrun simctl io "$udid" screenshot "$out/shot-${elapsed}s.png" > /dev/null 2>&1 || true
  if ! xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$bundle"; then
    echo "::warning::the app is no longer running after ${elapsed}s"
    break
  fi
done
pid=$(pgrep -f "ChaosPad.app/ChaosPad" | head -1 || true)
if [ -n "$pid" ]; then
  sample "$pid" 5 -file "$out/sample.txt" > /dev/null 2>&1 || true
  echo "▶ sample of the running app (pid $pid), first 200 lines"
  head -n 200 "$out/sample.txt" 2>/dev/null || true
fi
log="$data/Documents/log.txt"
cp "$log" "$out/log.txt" 2>/dev/null || true
echo "▶ log.txt ($(wc -l < "$log" 2>/dev/null || echo 0) lines), first 150"
head -n 150 "$log" || true
echo "▶ log.txt, last 60 lines"
tail -n 60 "$log" || true
rm -f "$data/Documents/sc3.sparse"
find "$HOME/Library/Logs/DiagnosticReports" -name 'ChaosPad*' -newer "$app" 2>/dev/null | while read -r report; do
  echo "▶ crash report $report"
  head -n 120 "$report"
  cp "$report" "$out/" || true
done
