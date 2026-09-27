# TranscriptionCenterTests.crashedWorkerRetriesOnceAndCommitsAdoptedThenCandidate()

- **ID:** 0001
- **Status:** open
- **Date observed:** 2026-09-27
- **Test:** `apps/macos/App/Tests/TranscriptionCenterTests.swift` → `crashedWorkerRetriesOnceAndCommitsAdoptedThenCandidate()`
- **Original command:** `mise //apps/macos:check`
- **Worker configuration:** Mise ran the macOS check tasks concurrently; `test:app` used Xcode's default test configuration on the local Mac.
- **Failure:** `Crash: My Screen Cam Dev at +[XCTWaiter _synchronouslyWaitForTimeInterval:]`. The Xcode test operation took 20.843 seconds; the failed case's duration was not reported. Result bundle: `apps/macos/build/DerivedData/Logs/Test/Test-MyScreenCam-2026.09.27_14-10-57-+0100.xcresult`.
- **Suite counts:** 29 total, 28 passed, 1 failed.
- **Isolated rerun:** From `apps/macos`, `mise exec -- scripts/dev/xcodebuild.sh -project MyScreenCam.xcodeproj -scheme MyScreenCam -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -quiet -only-testing:MyScreenCamAppTests/TranscriptionCenterTests test` → passed. The failing case also passed when selected alone.
- **Hypothesis:** The failure depends on test-suite execution or concurrent check load: the aggregate run crashed in `XCTWaiter`, while the file-level and case-level reruns passed. The result bundle does not identify a code-level cause.
- **Follow-up:** A second `mise //apps/macos:check` passed all tasks, including the aggregate app tests.
