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
11. **Folder is read through its grant**: pick a folder of non-media files (PDF, txt,
    zip) on API 30+; every file is counted (not "nothing to lock"), the run asks for
    no second permission for that folder, and no `latch_src` copies remain in the app
    cache afterwards. Repeat with "Include subfolders" and with delete-originals.
12. **Interrupted run** (delete-originals on): kill the app mid-run (desktop: kill the
    process; Android: swipe away or force-stop). Expected: every original that is gone
    has a verified `.latch` beside it; none is missing its container. Re-pick the same
    folder and run again.
    - *Decrypt:* files already unlocked are skipped as "not a Latch container"; the rest
      finish. A container whose original-removal was cut off is unlocked again and its
      output takes a `_2` suffix (`x.pdf_2`), never overwriting.
    - *Encrypt:* the review step counts finished files as "already look like Latch
      containers" and, if the run proceeds, locks them a second time (FR-009 states
      the count, it does not exclude them). An original whose container was written
      but not yet removed is locked again to `<name>_2.latch`.
    - A hard kill can leave `<name>.latch.tmp` beside the output on desktop/iOS (the
      write is `.tmp` then rename); Android staging is swept at the next app start.
      Enumeration does not exclude `.tmp` files.

## Device matrix (T076) — run before any release

Not run yet. Each row needs a physical device; record the result in the Result
column (device, Android version, build row from Settings → About, pass/fail, notes).
Use a **dev build** (separate `.dev` install) so a release's grants are untouched.

| # | Environment | Scenarios | Look for | Result |
|---|-------------|-----------|----------|--------|
| D1 | Samsung (One UI) picker | 10, 11, 12 | Folder pick seeds at the chosen folder or opens at root (both fine); every file counted; no second prompt; no `latch_src` left in cache | |
| D2 | Xiaomi/MIUI-HyperOS picker | 10, 11, 12 | Same as D1; some OEM pickers ignore `EXTRA_INITIAL_URI` | |
| D3 | Cloud-provider folder (Drive or OneDrive) | 11 | Unresolvable folder → one prompt, answer remembered; staging reads through the grant; a refused delete keeps both copies | |
| D4 | Forced low-memory kill mid-run (Developer options → "Don't keep activities" plus `adb shell am kill`, or fill RAM) | 12 | Relaunch sweeps staging; every vanished original has a container; rerun finishes | |
| D5 | Shared-key mode with delete-originals on a folder of 50+ files | 4, 6 | Faster than per-file mode (only the first verify pays Argon2); all containers still decrypt with the passphrase | |
| D6 | TalkBack, both folder screens, both progress screens, both result screens | traversal | Reading order top to bottom; switch and radio subtitles are read; "Change/Choose" output-folder button reads with context; progress reads "N%"; the result screen is announced on arrival | |
| D7 | Large text (200%) and small phone width | review screens | Nothing clipped; the tall review lists scroll | |

Localisation of the new screens stays deferred with the rest of the app
(`docs/RELEASE_READINESS.md`): copy, pluralisation and size/duration formatting are
hard-coded English.
