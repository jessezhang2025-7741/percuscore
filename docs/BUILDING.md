# Build and install

## Toolchain

Use a Mac with full Xcode 26 or newer, an installed iOS platform SDK and Python 3. The deployment target is iPadOS 17. Open Xcode once to complete its setup. These commands select Xcode for the current shell without changing the Mac's global developer-tool setting:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
python3 --version
```

On an Apple silicon Mac, use an ARM-native Python installation. If `python3`
points to an older Intel Homebrew installation and Git/Xcode subprocesses fail
with an incompatible-architecture error, use `/usr/bin/python3` in the commands
below (with `DEVELOPER_DIR` set as above).

Adjust the path if Xcode has a different name. The project uses only Apple SDKs; `Package.swift` has no external package dependencies. It is a core-test package, not the app launch entry point.

## Simulator

Open `Percuscore.xcodeproj`, choose the shared Percuscore scheme and an installed iPad Simulator, then Run. No developer Team is committed to the public project. For an unsigned build:

```sh
xcodebuild -project Percuscore.xcodeproj -scheme Percuscore \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Physical iPad

1. Add your Apple Account in Xcode Settings.
2. In the Percuscore target's Signing & Capabilities, enable automatic signing and select your own Team.
3. Choose a unique Bundle Identifier, for example `com.yourname.percuscore`; the example is not a registered identifier.
4. Connect and unlock the iPad, trust the Mac, and enable Developer Mode when prompted.
5. Select the device and Run; follow any on-device developer-trust prompts.

Keep personal Team and bundle changes local. Project regeneration preserves local signing and version settings, so review the project diff before contributing.

A free Personal Team's provisioning profiles expire 7 days after issuance. Apple requires rebuilding and reinstalling after expiry. See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/) and [running on a device](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device).

Do not uninstall an existing copy as a troubleshooting step without a verified library backup. Changing Team or Bundle Identifier can change app identity; do not assume existing data will be inherited. Export a `.percuscorebackup` and check recovery first.

## Source downloads and build identity

Both a Git clone and a source ZIP contain the build inputs. A Git checkout records its commit and clean/modified state in the built app. A ZIP without `.git` reports unavailable source identity; that does not prevent building. Never put private scores or signing certificates in the repository.

## Checks

```sh
python3 scripts/verify.py --level quick
python3 scripts/verify.py --level full
```

The full suite needs an available iPad Simulator. Results go to ignored `dist/validation/` folders and distinguish failed checks from checks not run. Release-level performance and manual device acceptance have additional requirements: [validation runner](VALIDATION-RUNNER.md).

For the individual native helpers, pass an explicit available Simulator UUID;
there is no developer-specific default destination. The unified validator above
selects an available iPad Simulator and supplies the argument automatically.

```sh
xcrun simctl list devices available
python3 scripts/run_reader_checks.py <SIMULATOR-UUID>
python3 scripts/run_toolbar_ui_checks.py <SIMULATOR-UUID>
```

## Prepared GitHub Actions workflow

The workflow uses the `macos-26` hosted image and selects Xcode 26.6, listed in
[GitHub's runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md).
Checkout is pinned to an [official commit](https://github.com/actions/checkout/commit/de0fac2e4500dabe0009e67214ff5f5447ce83dd)
that uses Node 24. The workflow requests read-only repository contents permission,
does not persist checkout credentials and does not upload local diagnostic logs.
Its first hosted run is pending publication; a local build is not proof of a
passing GitHub Actions run. Hosted software availability should be rechecked when
the workflow is next updated.
