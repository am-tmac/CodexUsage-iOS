# CodexUsage 2.0 / build 30 — refresh reliability

## Artifact

- Unsigned IPA: `Dist/CodexUsage-widget-build30-unsigned.ipa`
- Size: 1,395,458 bytes
- SHA-256: `f256436058c02acfdf0434d458588ca3cf51c783d0d6754481a2e31cdf2d3054`
- App and extension: version 2.0, build 30, minimum iOS 17.0, arm64.
- Identifiers/groups match the untracked private configuration; no signing identifiers are reproduced here.
- No embedded profiles or code signatures; use the existing phone-side signer for an overlay installation.

## Changes

1. Legacy Claude session cleanup deletes only the legacy Keychain item. OAuth snapshots and refresh-attempt/backoff records are preserved when legacy items are absent, already removed or deletion fails.
2. Claude usage 403 is a distinct safe access-denied state; it does not rotate tokens or claim a particular region restriction. Usage 401 still allows only one App-side rotation/retry.
3. A Claude widget whose bearer expired or was revoked records `needsAppRefresh`. Serving cache does not count as success. Only actual fresh usage clears the marker; the extension never renews Claude tokens. The widget shows an open-App action and stale-cache state. A medium widget with any slot needing renewal directs the shared control to the App.
4. Refresh errors are attributed to each provider/account card, remain visible when collapsed, keep the old timestamp and data, and provide targeted retry. Success clears only that card. Arbitrary localized error bodies are not surfaced.
5. Accessibility-sized summaries use a multiline fallback. Compact 28/36pt visuals retain their dimensions while outer hit areas use 44pt. Menus/expand controls include account context, and custom animations respect Reduce Motion.
6. Provider colours, marks, system TabView and DeepSeek wallet geometry are retained. No iCloud, Mac app, charts or sample-data mode were added.
7. XCTest hosts do not initialize storage-backed UI or auto-fetch. App regressions inject fetch closures and use isolated temporary containers.

## Review follow-up (same build 30)

- Medium widget: a Claude slot needing App renewal no longer disables the other slot's in-widget refresh; open-App appears only when no displayed slot can refresh.
- A persisted App-side token rotation clears the widget renewal marker even if the following usage request fails (the failure still counts).
- DeepSeek per-account refresh while another refresh runs reports busy instead of the card's previous error.
- Corrected the stale legacy-cleanup comment in `UsageModel.init`.

## Executed verification

All commands were run on the actual final source unless identified as RED evidence:

- `Logs/build30-claude-red.log`: intended regression failures before fixes.
- `Logs/build30-claude-green.log`: targeted 41 tests / 0 failures.
- `Logs/build30-app-red.log`: intended App regressions before fixes.
- `Logs/build30-app-green.log`: targeted signed simulator 8 tests / 0 failures.
- `Logs/build30-a11y-red.log`: static accessibility contract failed before implementation.
- `python3 Tests/widget_refresh_contract.py -v`: 19 tests passed (`Logs/build30-contract.log`).
- `python3 Tests/signing_configuration_test.py`: 1 test passed (`Logs/build30-signing-contract.log`).
- `python3 Tests/build9_contract.py`: 3 tests passed (`Logs/build30-legacy-contract.log`).
- `swift test`: 82 tests / 0 failures / 0 skips (`Logs/build30-review-swift.log`). This target includes ReviewFixTests but excludes the SwiftUI views and iOS-only storage tests.
- Signed simulator suite: 76 tests / 0 failures / 0 skips (`Logs/build30-review-simulator.log`). The Xcode target has its own source membership and does not include ReviewFixTests or SummaryCountdownTests; these are covered by SwiftPM, so the two totals are not directly comparable.
- Device Release build succeeded (`Logs/build30-release.log`).
- Packager succeeded (`Logs/build30-package.log`); verified current App/widget markers, four logo assets, private ID/group continuity, arm64, unsigned state and ZIP integrity. assetutil emitted a duplicate-class diagnostic but exited successfully and asset assertions passed.
- Independent IPA inspection confirmed both Info.plists, checksum, size and unsigned state.
- `git diff --check` passed. Private-config values were checked in memory against the diff/new packager: no matches. No private values were logged.

## Reproduce final build

```sh
python3 Tests/widget_refresh_contract.py -v
swift test
xcodebuild -project CodexUsage.xcodeproj -scheme CodexUsage \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath Build30Sim CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
  -parallel-testing-enabled NO test
xcodebuild -project CodexUsage.xcodeproj -scheme CodexUsage -configuration Release \
  -sdk iphoneos -xcconfig Configuration/Private.xcconfig -derivedDataPath Build30Direct \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CURRENT_PROJECT_VERSION=30 build
python3 Scripts/package_widget_build30.py
```

## Phone-side acceptance still required

- Re-sign using the same identifiers and overlay-install, then confirm existing accounts remain accessible.
- Reopen with temporary network loss: Claude retains the last successful cache.
- Refresh a failing account: error and old timestamp appear on that card; retry does not refresh other providers.
- Claude widget expired authorization shows open-App renewal; refreshing successfully in the App restores its widget control.
- Check real finger hit-testing, VoiceOver labels, very large text and Reduce Motion on the phone. The expanded hit regions are compile/static verified, not measured on hardware.
- Validate live OAuth/usage and WidgetKit rendering/scheduling under the phone's actual signature. No real account requests were made during this build.

Changes are on `fix/build30-refresh-reliability`; no commit or remote push was performed.
