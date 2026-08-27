# Quickstart: Codec Version Strategies

Runnable validation scenarios that prove the feature end-to-end. Prerequisites: repo root,
`flutter pub get` done, `sodium` native assets working (existing flow).

## Scenario A — Neutrality: nothing moved

The refactor's defining check. After the extraction commit, the pre-refactor fixtures must pass
**unedited**:

```sh
cd packages/myenc_core
flutter test test/codec_freeze_test.dart          # freeze guard, untouched
cd ../myenc_adapters
flutter test test/golden_vectors_test.dart         # golden vectors, untouched
flutter test test/compat_v1_test.dart              # pre-refactor .latch corpus decrypts
cd ../myenc_core
flutter test test/fixtures_header_corpus_test.dart # header corpus encodes byte-identically
```

Expected: all green, zero test-file edits in the change set (FR-009, SC-003).

## Scenario B — Machinery: the totality guard is real

Temporarily remove the v1 entry from the dispatch table and run the totality test — it must go
red. Restore it. (This is the SC-004 negative demonstration; perform it once in review, do not
commit the removal.)

## Scenario C — The failure modes hold on pre-refactor bytes

In `compat_v1_test.dart`: decrypt a fixture with the wrong passphrase → fast failure at the key
wrap, body untouched; decrypt the tampered fixture → chunk-tag failure, no partial plaintext
emitted (FR-007).

## Scenario D — Full gates (what CI runs)

```sh
dart format --set-exit-if-changed .     # from repo root
cd packages/myenc_core     && flutter analyze --no-pub && flutter test
cd packages/myenc_adapters && flutter analyze --no-pub && flutter test
cd ..                       && flutter analyze --no-pub && flutter test
```

Expected: test counts at or above baseline (core 86, adapters 36, app 143) plus the new suites
(SC-005). Android gate N/A — no Kotlin touched.

See [the strategy contract](contracts/format_strategy_contract.md) and
[the data model](data-model.md) for the rules these scenarios pin.
