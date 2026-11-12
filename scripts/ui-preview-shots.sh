#!/bin/bash
# Build DriftUIPreview (project-preview.yml) and screenshot its screens
# on one simulator per wanted iOS major version ($WANT_MAJOR, e.g.
# "17" or "18 26"). Output: build/preview-shots/ios<major>-<screen>.png
#
# A wanted runtime that the runner image does not carry is a loud skip,
# not a failure — the images' runtime sets change under us. Producing
# zero screenshots at all IS a failure.
set -uo pipefail

SCREENS="tutorial local norespring respring about theme"
SHOTS="build/preview-shots"
mkdir -p "$SHOTS"

xcodegen generate --spec project-preview.yml

xcodebuild build \
  -project DriftPreview.xcodeproj \
  -target DriftUIPreview \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath build/preview-dd \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

APP="build/preview-dd/Build/Products/Debug-iphonesimulator/DriftUIPreview.app"
if [ ! -d "$APP" ]; then
  echo "error: preview app was not built ($APP missing)" >&2
  exit 1
fi

# Print the identifier of the newest available iOS runtime for a major
# version (e.g. com.apple.CoreSimulator.SimRuntime.iOS-17-5), or nothing.
runtime_for_major() {
  xcrun simctl list runtimes -j | python3 -c "
import json, sys
major = sys.argv[1]
candidates = []
for runtime in json.load(sys.stdin)['runtimes']:
    if not runtime.get('isAvailable', False):
        continue
    ident = runtime['identifier']
    if '.SimRuntime.iOS-' not in ident:
        continue
    version = ident.rsplit('iOS-', 1)[1].replace('-', '.')
    parts = version.split('.')
    if parts[0] == major:
        candidates.append((tuple(int(p) for p in parts), ident))
print(max(candidates)[1] if candidates else '')
" "$1"
}

made=0
for major in $WANT_MAJOR; do
  runtime="$(runtime_for_major "$major")"
  if [ -z "$runtime" ]; then
    echo "::warning::no available iOS $major simulator runtime on this runner — skipped"
    continue
  fi
  echo "== iOS $major ($runtime) =="
  udid="$(xcrun simctl create "DriftProbe-$major" "iPhone 15" "$runtime")"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP"
  for screen in $SCREENS; do
    xcrun simctl launch --terminate-running-process "$udid" \
      com.sociart.drift.preview -ProbeScreen "$screen" >/dev/null
    sleep 3
    if xcrun simctl io "$udid" screenshot "$SHOTS/ios$major-$screen.png" >/dev/null 2>&1; then
      made=$((made + 1))
    else
      echo "::warning::screenshot failed: iOS $major / $screen"
    fi
  done
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
done

echo "screenshots produced: $made"
ls -la "$SHOTS" || true
[ "$made" -gt 0 ]
