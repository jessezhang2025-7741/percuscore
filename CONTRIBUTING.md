# Contributing

Issues and pull requests are welcome. This is a personal project; there is no guaranteed response time or release schedule.

Before filing a bug, include the app version/build, iPad model, iPadOS version, reproduction steps, expected behavior and actual behavior. Use an original or synthetic PDF for reproduction. Do not upload private scores, personal libraries, signing credentials or unreviewed diagnostics.

For changes, keep a pull request focused and describe the problem, resulting behavior and checks actually run. Preserve existing library, annotation and backup data. Add regression coverage for behavior fixes; document schema or compatibility changes. Use [the build guide](docs/BUILDING.md) and existing `scripts/verify.py` checks. Keep personal signing edits out of commits.

The root Xcode scheme builds the app; `Package.swift` covers core tests. Changes involving reading or ink need appropriate native/UI checks and honest disclosure of physical-device checks not performed. Do not claim Simulator input verifies Apple Pencil or palm rejection.

By submitting a contribution, you agree to license your contribution under this project's MIT license and confirm you have the necessary rights. You retain copyright in your contribution. Third-party content must retain applicable notices.

Git commits expose their author and committer email addresses. If you want to
keep yours private, configure this checkout to use your GitHub-provided
`noreply` address before committing, and inspect commit metadata before pushing.
The setting is local to a checkout and is not inherited by a new clone. Changing
it does not remove an email already present in older commits. See
[GitHub's commit email guide](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address).
