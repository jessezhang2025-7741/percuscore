# Privacy and local data

Percuscore is designed for local, offline use. The checked-in application has no built-in analytics SDK, application account, server backend or network synchronization service.

Imported PDFs are copied to the app's local library. Saved PencilKit ink, recoverable drafts, bookmarks, page views, setlists and settings are stored locally. Recently deleted scores remain stored until permanently removed. The library may be visible through Files because file sharing is enabled.

Files providers and destinations selected by the user, including cloud storage, have their own network behavior and policies. User-initiated sharing, PDF export, library backup and diagnostic export can transfer files to the chosen app or service. GitHub interactions are separate from the iPad application's data storage.

Optional local diagnostics record limited reader-state metadata. Review any exported report before sharing it; device-acceptance and validation reports can contain device, system, source and local-environment details. Do not publish private PDFs, handwriting or whole libraries as bug attachments.

Uninstalling the app may delete local data. Make and verify a library backup first: [backup guide](docs/BACKUP.md). The MIT license does not change rights in users' imported scores or annotations.
