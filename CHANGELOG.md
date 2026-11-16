# Changelog

## Initial source preview

- Publish the existing native iPad PDF score reader as MIT-licensed source.
- Include PDF import, local library organization, PencilKit markings, per-page
  views and crop, bookmarks, setlists, full/half-page turns, PDF export, backup
  recovery and recently deleted storage.
- Provide neutral signing defaults, English and Chinese introductions, build
  instructions and contribution/privacy/security guidance.
- Fix Restore also opening the neighboring permanent-delete confirmation in a
  Form row by giving those buttons independent interaction styles. The public
  source build is 0.1.0 / 8; no existing iPad installation is updated by this.
- Retain storage formats, core data handling and required resources from the
  development baseline. Public packaging excludes private history and diagnostics.
- Require an explicit Simulator destination in the native test helpers rather
  than shipping a developer's local device identifier.
- Make the disposable UI host fit its actual window and select sidebar rows
  explicitly. The long scrubbing workload opts into visible test-host controls;
  separate checks retain the production auto-hide deadline.

See [validation status](docs/VALIDATION-STATUS.md) for checks actually completed
and their limits. This preview does not certify extended physical-device use.
