#!/bin/sh
# Screenshot driver: build → install → launch with fixtures → capture PNGs.
# Uses a dedicated simulator (CodexUsage-Shots) and derived data path so a concurrently running
# agent on the shared "iPhone 17 Pro" device cannot interleave launches with these captures.
set -e
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UDID=075C11B2-9FB8-4A6F-BE16-5F91E2287924
BID=com.personal.CodexUsage
DD=BuildShots
APP=$DD/Build/Products/Debug-iphonesimulator/CodexUsage.app
xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null 2>&1 || true
xcrun simctl ui $UDID appearance dark >/dev/null 2>&1 || true
if [ "$1" != "nobuild" ]; then
  xcodebuild -project CodexUsage.xcodeproj -scheme CodexUsage \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath $DD CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build 2>&1 | grep -E "error:|BUILD" | head -20
fi
xcrun simctl install "$UDID" "$APP"
shot() { # $1 = UI_FIXTURE value ("" = none), $2 = output name
  if [ -n "$1" ]; then
    SIMCTL_CHILD_UI_FIXTURE="$1" xcrun simctl launch --terminate-running-process "$UDID" "$BID" >/dev/null
  else
    xcrun simctl launch --terminate-running-process "$UDID" "$BID" >/dev/null
  fi
  sleep 5
  xcrun simctl io "$UDID" screenshot "Logs/$2.png" 2>/dev/null
  echo "captured Logs/$2.png"
}
shot "" ui-empty
shot 1 ui-dark-expanded
shot collapsed ui-dark-collapsed
shot settings ui-dark-settings
shot widget ui-widget-small
xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'senderImagePath CONTAINS "CodexUsage"' 2>/dev/null | grep -i "fatal error" | tail -3 || true
echo DONE
