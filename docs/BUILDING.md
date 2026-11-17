# Build and install

[简体中文](BUILDING.zh-CN.md) · [Back to README](../README.md)

This is free installation from source, not a downloadable iPad app. You need a Mac; an iPad alone, Windows or Android cannot use this installation path. The project targets iPad, not iPhone. No TestFlight, App Store or signed IPA is provided.

## 1. Download and open

1. On the Mac, [download the latest source ZIP](https://github.com/jessezhang2025-7741/percuscore/archive/refs/heads/main.zip). It follows `main` and includes maintained fixes. No GitHub account is needed.
2. Double-click the ZIP in Finder to extract it. Keep the extracted folder together; open **Percuscore.xcodeproj** inside it with Xcode. Do not open `Package.swift` to launch the app.
3. For a fixed original preview, use [v0.1.0-preview.1](https://github.com/jessezhang2025-7741/percuscore/archive/refs/tags/v0.1.0-preview.1.zip), which does not include later fixes.

For Terminal commands below, first change into the extracted project folder (type `cd ` and drag the folder from Finder into Terminal, then press Return).

## 2. Prepare Xcode

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

## 3. Try the iPad Simulator

Open `Percuscore.xcodeproj`, choose the shared Percuscore scheme and an installed iPad Simulator, then Run. No developer Team is committed to the public project. For an unsigned build:

```sh
xcodebuild -project Percuscore.xcodeproj -scheme Percuscore \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 4. Install on your iPad

1. In **Xcode → Settings → Accounts**, add your own Apple Account. A free Personal Team is sufficient for this source-installation path; a paid membership is not required.
2. In the left project navigator, select the blue **Percuscore** project. Under **TARGETS**, select **Percuscore**, then **Signing & Capabilities**.
3. Enable **Automatically manage signing**. Under **Team**, choose your account's Personal Team. Team identifies the account signing your app; the public project deliberately has no author's Team selected.
4. Set a unique **Bundle Identifier**, such as `com.yourname.percuscore`, replacing `yourname` with your own unique text. This is the app's identity, not its display name; the example is not a reserved identifier. If Xcode says it is unavailable, choose another.
5. Connect the unlocked iPad to the Mac with a cable. Accept **Trust This Computer** on the iPad. In Xcode's destination picker beside the scheme, select your iPad and let pairing/setup finish.
6. Enable **Settings → Privacy & Security → Developer Mode** on the iPad when prompted. Restart and confirm as requested. If the option is not yet shown, finish Xcode pairing first. Follow any developer-trust prompts; if required, use **Settings → General → VPN & Device Management** to trust your own developer identity.
7. Click Xcode's **Run** triangle (⌘R). Keep the iPad unlocked while the app builds and installs. In Percuscore, choose **Try an original practice score** or **Import PDF**.

If signing fails, read Xcode's specific account/device message and check the selected Team, unique identifier and device pairing. Do not delete an existing installation to fix signing.

Keep personal Team and bundle changes local. Project regeneration preserves local signing and version settings, so review the project diff before contributing.

A free Personal Team's provisioning profiles expire 7 days after issuance. After expiry, reconnect the iPad, open the same project, keep the same Apple Account/Team and Bundle Identifier, and Run again to renew the installation in place. Keep that project and its signing settings for the next renewal; do not uninstall first. See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/) and [running on a device](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device).

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

## Hosted source checks

The original public preview commit [`4eb5a6f`](https://github.com/jessezhang2025-7741/percuscore/commit/4eb5a6f0ab809831608e6372246dbd900d1963d1) has successful hosted runs for [main](https://github.com/jessezhang2025-7741/percuscore/actions/runs/43806055141) and [the release tag](https://github.com/jessezhang2025-7741/percuscore/actions/runs/43807180223). These source checks do not certify signing with a new user's account or physical-device acceptance. Check [Actions](https://github.com/jessezhang2025-7741/percuscore/actions) for the revision you download and [validation status](VALIDATION-STATUS.md) for the tested scope.
