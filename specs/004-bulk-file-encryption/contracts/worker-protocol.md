# Contract: worker task-map extensions

Message protocol is **unchanged**: `file_start`, `progress`, `file_done`, `error`,
`done`. "Last per-file result before final `1.0`" still holds and
`test/app_crypto_batch_test.dart` must pass unmodified.

## encrypt
Per-file output paths: parallel `outRelPaths` list (`List<String?>`, same length as `files`; null = historical flat layout). Batch level: `outputDir`, `deleteOriginals`,
`keyMode` (`perFile`|`sharedPerBatch`), `verifyBeforeDelete` (true whenever
`deleteOriginals` is true). With `sharedPerBatch`, the worker derives one
`BatchWrapKey` before the first file and disposes it in `finally`.

## decrypt
Per-file output paths: parallel `outRelPaths` list (`List<String?>`, same length as `files`; null = historical flat layout). Batch: `outputDir`, `deleteContainers`. With `deleteContainers`, the worker re-reads the container independently, decrypts, compares to the restored file, and deletes only on exact match (FR-035b/c).
Container removal happens only after the plaintext is fully written and its length
matches the decoded stream (FR-035b).

## file_done additions
`verified: bool`, `sourceRemoved: bool` alongside existing fields.

## Teardown
`_runBatch` already sweeps the in-flight `<outPath>.tmp`. Bulk additionally sweeps the
**staging directory tree** on teardown before `done`, because staged decrypt output is
plaintext (Principle IV). Pinned by a plain-`test()` real-isolate test.

## Pre-flight (main isolate, before spawn)
walk (via `Isolate.run`) → space check (destination + staging) → >10,000 files
confirmation → output planning (grant prompt, may yield `OutputPlan.cancelled`).
Refusal at any step writes and stages nothing.
