# Versioning and source identity

The initial public repository is a curated source snapshot of an earlier private development history. Earlier private commit IDs and raw device records are not shipped. The public history starts here. A small UI fix found during preparation isolates the Restore and permanent-delete buttons so tapping Restore does not also open the deletion confirmation; storage formats and library data handling are unchanged.

`MARKETING_VERSION` is the displayed app version; `CURRENT_PROJECT_VERSION` is its build number. The imported baseline was 0.1.0 / 7; the public source preview uses 0.1.0 / 8 to distinguish the UI correction. This does not indicate an installation on the author's device. A build number is not proof of real-device acceptance. Increment it before deliberately distributing a new device build.

The build phase writes the current public Git commit and clean/modified/unavailable state into the built app. A source ZIP without Git metadata reports unavailable. Do not associate an earlier installed build's private commit with a new public commit.

Preview source tags may use `v0.1.0-preview.N` after project, tool, core and unsigned Simulator-build checks pass and limitations are recorded. Preview tags are not stable-release approvals. Stable/device release tags require the existing release-level automated checks and recorded manual device acceptance; missing checks cannot be marked passed.

Use focused commits such as `fix(reader): ...`, `feat(backup): ...` and `docs: ...`. Do not force-push published history as a cleanup shortcut.

For source archives, run `python3 scripts/package_release.py` from a clean committed checkout. For an independent Git bundle, ZIP and checksum manifest, run `python3 scripts/backup_source.py --output-dir <directory-outside-this-repository>`. These tools do not back up the iPad score library. Export and verify that separately inside the app.
