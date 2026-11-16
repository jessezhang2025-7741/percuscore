# Public source preview validation

Prepared on 2026-11-15. Public source version: **0.1.0 / build 8**. This is a source preview, not a stable-release or physical-device certification.

## Latest public-code checks

Toolchain: Xcode 27.2 (27B52), Apple Swift 6.4.2; UI checks used an iPadOS 27.2 Simulator. Other supported OS/toolchain combinations have not been certified by this run.

| Check | Actual result |
| --- | --- |
| Project references and configuration | Passed |
| Python tooling tests, including explicit Simulator arguments | 50 passed, 0 failed, 0 skipped |
| Core XCTest suite | 131 passed, 0 failed, 0 skipped |
| Real-Simulator targeted UI regressions | 3 passed, 0 failed, 0 skipped |
| Public source consistency during quick checks | Passed; clean committed source |
| GitHub Actions | Configuration prepared; hosted execution pending publication |

The code checks above ran against public commit `61b461763476b77a61d6cbeb814ea749d3f6f486`. The targeted UI run checks rapid 120-page scrubbing, normal production auto-hide, and delete/restore/cache interaction including the assertion that Restore must not open a permanent-delete confirmation. Later documentation-only edits do not change these tested code inputs.

## Broader baseline run and fixes

The initial full local run passed 46 then-existing tool tests, 131 core tests, 131 native reader tests, the unsigned Simulator build and one live-canvas save/relaunch regression. Its general UI suite ran 38 tests: **36 passed and 2 failed**. That original full result remains failed; it has not been relabeled as passing.

Follow-up identified test-host timing, window sizing and sidebar/scroll targeting issues, plus a real Form-row interaction defect: tapping Restore also opened its neighboring permanent-delete confirmation. Build 8 gives those buttons independent styles. The public test host can hold controls visible only for the long scrubbing workload; the separate normal auto-hide check still uses the shipping deadline.

After those corrections the three targeted checks above passed. The entire 38-test UI suite and the 131-test native reader suite were **not rerun after the final correction**. Baseline results are therefore separate evidence, not a claim that a fresh full run of build 8 passed. Existing SwiftUI view-update and Xcode debug-information warnings appeared in local logs; a green check does not mean those warnings were absent.

## Scope and privacy

No personal library, imported score, signing certificate, original device installation report or raw local log is distributed with the source. Demo/test scores are generated from original or synthetic material. Local backup, audit and validation reports are retained privately.

Physical Apple Pencil, palm rejection, long rehearsal, keyboard-mode pedals, real Files providers, original-score performance and manual backup/recovery acceptance remain outside these automated checks. Use [the iPad checklist](IPAD-CHECKLIST.md) and [device acceptance guide](DEVICE-ACCEPTANCE.md).

Final local packaging also built both a clean Git clone and an extracted Git source ZIP successfully with signing disabled. Both reported 0.1.0 / build 8; the clone reported clean Git source identity and the ZIP correctly reported unavailable Git identity. Project regeneration in the clean clone was byte-identical and retained neutral signing. Raw paths/logs remain private. No remote build result is claimed.
