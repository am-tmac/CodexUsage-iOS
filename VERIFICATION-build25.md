# Build 25 verification (2.0 build 25)

Build 25 keeps the build 24 UI and ships the first batch of review fixes (commit on `fix/review-p1`).

## Automated evidence
- `swift test`: 53 tests, 0 failures (build 24 HEAD: 41 tests, 1 failure). 12 new regression tests in `Tests/ReviewFixTests.swift`, each confirmed failing before the fix.
- `Tests/widget_refresh_contract.py`, `build9_contract.py`, `signing_configuration_test.py`: OK.
- Release iphoneos build with `-xcconfig Configuration/Private.xcconfig`: BUILD SUCCEEDED (`Logs/build25-release.log`).
- `Scripts/package_widget_build25.py`: private bundle IDs, App Group, keychain group, 2.0 (25), arm64, unsigned, extension present, new-string markers present, old paste-code message absent (`Logs/build25-package.log`).
- IPA: `Dist/CodexUsage-widget-build25-unsigned.ipa`, sha256 `34e328eeb12f7832538562aefbb80fb79eb3efd63c236824a3544547464ccfff`.

## Not verified (phone-side)
- Signed install over build 24 keeps existing logins.
- Claude paste-code login end to end; Claude/Codex token rotation under real accounts.
- Antigravity refresh keeps the last good data on failure; widget refresh throttling on device.
- Signed-simulator `StorageTests` suite was not run for this build.
