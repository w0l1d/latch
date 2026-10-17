# Contract: preferences and UI

| Key | Values | Default |
|---|---|---|
| `bulk.keyMode` | `perFile`, `sharedPerBatch` | `perFile` |
| `bulk.outputPlacement` | `mirroredFolder`, `besideOriginals`, `flatFolder` | `mirroredFolder` |

- Recursion is not a preference.
- Settings → Bulk encryption: both options, with the plain-language per-file vs shared
  comparison from the spec (pros/cons) shown next to the toggle. Selecting
  `sharedPerBatch` shows the warning once at selection, never mid-operation.
- Folder selection screen shows: count, total size, skipped list with reasons,
  recursion toggle, placement (with override), and — when `deleteSources` is on — the
  disclosure that verification doubles read cost.
- Settings → Save folders wording is corrected so a folder granted only for encryption
  is not described as a save destination (FR-038); no per-grant provenance recorded.
