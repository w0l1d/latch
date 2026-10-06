# Quickstart: validating Bulk File Encryption

## Prerequisites
```sh
flutter pub get
```
Android scenarios need a device with API ≥ 30 and a folder of ~20 mixed files,
including one nested subfolder, a zero-byte file, a symlink (desktop only) and an
already-encrypted `.latch`.

## Automated gates (run per package)
```sh
dart format .
flutter analyze --no-pub && flutter test
cd packages/myenc_core && flutter analyze --no-pub && flutter test
cd ../myenc_adapters && flutter analyze --no-pub && flutter test
cd ../../android && ./gradlew :app:testDebugUnitTest   # only if Kotlin changed
```
Freeze guards (`codec_freeze_test.dart`, golden vectors) MUST pass unedited.

## Scenarios
1. **Non-recursive default**: select folder with a subfolder; only top-level files are
   encrypted; subfolder contents listed as "not included" (recursion off).
2. **Recursive + mirrored output**: toggle on; output tree mirrors source under the
   picked destination; every source file has exactly one `.latch`.
3. **Per-file independence**: corrupt one container; bulk decrypt reports that one
   failure and decrypts the rest.
4. **Batch mode**: with `sharedPerBatch`, N files finish with one Argon2 derivation
   (timing: ≈ one KDF, not N); all decrypt with the normal path; salts identical,
   DEKs/nonces distinct; independent-reference test passes.
5. **Header sniffing**: a renamed container (`.dat`) is decrypted; a text file named
   `x.latch` is skipped and listed.
6. **Verified deletion**: with delete-originals on, flip one byte in a staged container
   (test hook) → that original is kept, the failure is typed; others deleted.
7. **Cancellation**: cancel bulk decrypt mid-run → no plaintext remains in staging or
   destination for unfinished files (assert directory empty).
8. **Pre-flight space**: with a destination too small (desktop: small tmpfs) → refused
   before any write, naming which location is short.
9. **>10,000 files**: confirmation required; UI stays responsive (frame times).
10. **Android single grant**: choose a folder once; no second prompt; one entry added
    to Save folders; revisiting the same folder adds none.
11. **Device read test (carried risk)**: confirm the worker can read/walk the picked
    folder's real path on API 30+; if not, stop and revisit R6.
