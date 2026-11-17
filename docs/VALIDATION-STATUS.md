# Public source preview validation

Audit completed on 2026-11-16 against public commit [`4eb5a6f0ab809831608e6372246dbd900d1963d1`](https://github.com/jessezhang2025-7741/percuscore/commit/4eb5a6f0ab809831608e6372246dbd900d1963d1), tagged `v0.1.0-preview.1`, app **0.1.0 / build 8**. These results describe that snapshot, not every later `main` revision or a stable-release certification.

## Verified results

Local toolchain: Xcode 27.2 (27B52), Apple Swift 6.4.2, iPadOS 27.2 Simulator. Other supported toolchain/OS combinations were not certified by this run.

| Check | Actual result |
| --- | --- |
| Fresh public clone: project/configuration and source consistency | Passed |
| Python tooling tests | 50 passed |
| Core XCTest suite | 131 passed |
| Native reader tests | 131 passed |
| Real-canvas save/relaunch regression | 1 passed |
| UI suite | 32 passed before interruption; remaining 6 passed in a separate run |
| Anonymous release source ZIP: unsigned Simulator build | Passed |
| GitHub-hosted source checks | Passed on main and the release tag; links below |

The UI run reached its configured **900-second command timeout**. Process cleanup then reported `Operation not permitted`; the original overall report remains **failed**. The other six cases subsequently passed in a separate `.xcresult`. All 38 UI cases therefore have passing records **across split runs**, not one uninterrupted green full-suite run. The follow-up also logged an Xcode diagnostic `simctl` lookup warning.

Hosted runs for the public preview: [main, 43806055141](https://github.com/jessezhang2025-7741/percuscore/actions/runs/43806055141) and [tag, 43807180223](https://github.com/jessezhang2025-7741/percuscore/actions/runs/43807180223). These are source checks, not hosted physical-device or complete Simulator UI acceptance. Later revisions must be assessed using their own [Actions results](https://github.com/jessezhang2025-7741/percuscore/actions).

## Version provenance and earlier evidence

An earlier document called `61b461763476b77a61d6cbeb814ea749d3f6f486` a public commit. It was a **local preparation commit**, is not available in public Git history, and should not be used to locate this release. The public preview's app/core source matched that preparation baseline; publication also included test/CI fixes and documentation changes. It was not a documentation-only sequence.

The earlier baseline UI run had 36 passes and 2 failures. Targeted follow-ups passed after a Restore button interaction fix and test-host corrections. Those older results are distinct from the fresh public-clone audit above; neither failed full run has been relabeled as passing.

Clean-clone and source-ZIP builds succeeded without signing. The clone recorded Git source identity; the ZIP correctly reported that Git identity was unavailable. At the audited preview, build logs included a `PageTurnPreview.swift` actor-isolation warning under Swift 5 language mode. Passing builds do not imply warning-free logs or Swift 6 language-mode certification.

## Scope and privacy

This repository does not distribute personal libraries, imported scores, signing certificates, private device reports or raw local logs. Demo/test scores use original or synthetic material. Local audit records and result bundles remain private.

Physical Apple Pencil, palm rejection, long rehearsal, keyboard-mode pedals, every Files provider, real large-score performance, signing with a new user's account, and manual backup/recovery acceptance remain outside these automated checks. See [the iPad checklist](IPAD-CHECKLIST.md) and [device acceptance guide](DEVICE-ACCEPTANCE.md). A historical iPad installation is not certification of these behaviors.

## Maintenance follow-up — 2026-11-17

The maintenance changes passed 53 Python tooling tests and 131 core tests,
project checks and source-consistency checks. An unsigned Simulator build
succeeded, and the two page-preview actor-isolation warnings no longer appeared.
The built privacy manifest matched the source declarations for local settings
and elapsed-time measurement. The isolated Simulator opened the original
practice score and its markup tools. These checks do not replace the full
physical-device acceptance boundaries above.

The original public snapshot also completed [CodeQL setup](https://github.com/jessezhang2025-7741/percuscore/actions/runs/44145868127)
for Swift, Python and GitHub Actions. Check the current revision’s Actions and
Security pages for subsequent results; a completed scan is not proof that no
vulnerabilities exist.
