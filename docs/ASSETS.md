# Included assets and licensing

The project source and original bundled artwork are distributed under the root
[MIT license](../LICENSE). Third-party material, if introduced by a future
contribution, must be identified and retain its applicable notices.

- `Percuscore/App/SampleScore.swift` generates the bundled practice material
  programmatically. No third-party score PDF is bundled.
- `Percuscore/App/BackupPracticeLibrary.swift` and the acceptance/test fixtures
  generate synthetic material for validation rather than importing a personal
  score library.
- `scripts/make_icon.swift` defines the original geometric icon layers and
  fallback artwork. The app includes these SVG layers, their Icon Composer
  configuration and the generated fallback PNG.
- System frameworks, fonts and system-provided symbols are supplied by Apple's
  platform and are not relicensed by the project's MIT license.

Historical UI screenshots, private device reports and imported user scores are
not part of this source preview. Users retain their own rights and obligations
in imported scores and annotations; installing this app does not grant rights
to redistribute those works.
