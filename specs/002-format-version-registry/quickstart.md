# Quickstart: Verifying the Central Format-Version Registry

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Contract**: [contracts/format_version_contract.md](./contracts/format_version_contract.md)

This feature's deliverable is a *non*-change: the same containers decode, the same
containers are refused. So verification is less about exercising new behaviour than
about proving old behaviour is intact. The steps below are ordered so that the
strongest evidence comes first.

**Prerequisites**

- Flutter 3.44.2 (CI pin), Dart SDK `^3.12.2`
- `flutter pub get` at the repository root — resolves the path dependencies too
- Do **not** install a system libsodium or set `LD_LIBRARY_PATH`. `sodium` 4.x ships it
  via Dart native assets and `flutter test` bundles it. Doing so breaks the
  native-assets flow.
- Branch off `develop`, not `main` and not `001-folder-encryption`

---

## 1. Record the baseline before changing anything

The acceptance criteria are relative to `develop`, so capture it first. Without this,
"behaviour unchanged" is an assertion rather than a measurement.

```sh
git switch develop
cd packages/myenc_core     && flutter test 2>&1 | tail -3
cd ../myenc_adapters       && flutter test 2>&1 | tail -3
```

**Expected**: both suites green. Note the test counts — they are the reference for
step 4.

```sh
# Capture the file list whose non-modification is an acceptance criterion
git switch -c 002-format-version-registry
git rev-parse HEAD > /tmp/latch-002-base.txt
```

---

## 2. The primary acceptance instrument: golden vectors, untouched

This is the single most important check. The golden vectors are produced by an
independent Python reference implementation, never by the Dart code under test
(constitution Principle V), so they are the only evidence that decode behaviour did not
shift.

```sh
cd packages/myenc_adapters
flutter test test/golden_vectors_test.dart
git diff --exit-code -- test/golden_vectors_test.dart test/golden/
```

**Expected**: test passes, and `git diff --exit-code` **exits 0** — the fixtures and the
test file are byte-identical to the base. A non-zero exit here fails the feature
outright; regenerating the vectors to accommodate this work is forbidden.

---

## 3. The freeze guard, and the one permitted edit

The byte-layout assertions must pass untouched. The unknown-version case is retargeted
(FR-013), and the *sequence* below is what proves that retarget is a deliberate
hardening rather than a fix for a failure — which is what keeps it inside constitution
Principle II.

**3a — after the refactor, before the retarget:**

```sh
cd packages/myenc_core
flutter test test/codec_freeze_test.dart
```

**Expected: green, with the literal `2` still in the test.** This is the load-bearing
observation. It demonstrates the refactor did not break the guard, so the retarget that
follows cannot be a repair.

**3b — retarget as its own commit, then re-run:**

```sh
flutter test test/codec_freeze_test.dart
git show --stat HEAD          # touches exactly one test file, one assertion
```

**Expected**: green again, and the asserted value is unchanged (`firstUnknown == 2`
today). Green → green across a value-neutral commit.

> If step 3a is **red**, stop. The refactor changed decode behaviour. Do not proceed to
> 3b — retargeting the assertion at that point would be exactly the prohibited act of
> editing a freeze guard to make a failing test pass.

---

## 4. Everything else passes unmodified

```sh
cd packages/myenc_core     && flutter test
cd ../myenc_adapters       && flutter test
cd ../..                   && flutter test

# Exactly two test files may differ from the base: the new invariant file,
# and codec_freeze_test.dart. Nothing else.
git diff --name-only "$(cat /tmp/latch-002-base.txt)" -- '*_test.dart' 'packages/*/test/*'
```

**Expected**: all three suites green with counts matching step 1 plus the new file's
tests. The diff lists `packages/myenc_core/test/format_version_test.dart` (new) and
`packages/myenc_core/test/codec_freeze_test.dart` (retarget) — and nothing else.

---

## 5. The new invariants

```sh
cd packages/myenc_core && flutter test test/format_version_test.dart
```

**Expected**: green, covering — see [data-model.md](./data-model.md) for the full
statement of each:

| Check | Expectation |
| --- | --- |
| I1 — contiguity | Record keys are exactly `1..n`, starting at 1. Today `{1}`. |
| I2 — key/number agreement | Every entry's own number equals the key it is registered under. |
| I3 — full byte range | All 256 values have a defined outcome: known values resolve; `0` and everything from the boundary through `255` throw the version error. |
| I4 — write default | Is 1, and is not derived from the record's maximum. |
| Boundary derivation | The boundary is the smallest absent positive integer — today 2. |

---

## 6. Confirm the one intentional behaviour change

Version `0` is **accepted** on `develop` (verified empirically — the base gate is
`version > 1`) and must be **refused** after this change. It is the only input whose
behaviour differs; see [the contract](./contracts/format_version_contract.md) §3.

**Expected**: a container stamped `0x00` throws the version error. Covered by I3 above;
call it out in review so the tightening is not mistaken for an accident.

---

## 7. Extensibility, demonstrated then discarded

Proves spec SC-007 — that a future version costs one row — without shipping a row.

```sh
cd packages/myenc_core
# Temporarily add a row for version 2 to the record. Edit NOTHING else.
flutter test test/codec_freeze_test.dart test/format_version_test.dart
```

**Expected**: both still green, with **no test file edited**. The boundary has moved
from 2 to 3 on its own, and the freeze guard followed it because it names the boundary
rather than a value. This is the property the feature exists to buy.

```sh
git checkout -- lib/src/format/format_version.dart   # discard the throwaway row
```

**Expected**: the row is gone. It must not be committed — spec FR-011.

---

## 8. Constitution quality gates

All five gates from the constitution's Development Workflow section. There is no single
command; each package is verified separately, exactly as CI does.

```sh
cd "$(git rev-parse --show-toplevel)"
dart format --set-exit-if-changed .                                   # gate 1
flutter analyze --no-pub && flutter test                              # gate 2 (app)
cd packages/myenc_core     && flutter test && flutter analyze --no-pub # gate 3
cd ../myenc_adapters       && flutter test && flutter analyze --no-pub # gate 4
# gate 5 (cd android && ./gradlew :app:testDebugUnitTest) — N/A, no Kotlin changed
```

**Expected**: all green, no analyzer warnings. Gate 1 in particular fails CI before it
reaches analyze, so run it before committing. Gate 5 is recorded N/A rather than skipped
silently.

Note `flutter analyze` must be clean: `FileHeader.supportedVersion` is deliberately
**not** annotated `@Deprecated`, because
`deprecated_member_use_from_same_package` would then fire on its 11 in-repo references
and force the test churn the forwarding getter exists to avoid (research.md Decision 4).

---

## 9. Definition of done

- [ ] Golden vectors and their test pass with `git diff --exit-code` clean (step 2)
- [ ] Freeze guard observed green *before* the retarget commit (step 3a) — the evidence
      that the retarget is a hardening, not a fix
- [ ] Freeze guard green after the retarget, asserted value unchanged (step 3b)
- [ ] Exactly two test files differ from the base: one new, one retargeted (step 4)
- [ ] All 256 version byte values have a defined, tested outcome (step 5)
- [ ] Version `0` refused; called out in review as the one intentional change (step 6)
- [ ] Adding a throwaway row moves the boundary with zero test edits, and is discarded (step 7)
- [ ] All five constitution gates pass, gate 5 recorded N/A (step 8)
- [ ] No version-literal comparison remains anywhere in `packages/myenc_core` outside
      the record: `grep -rn 'version *[<>=]' packages/myenc_core/lib` returns nothing
      outside `format_version.dart`
- [ ] `docs/FORMAT.md` unmodified: `git diff --exit-code -- docs/FORMAT.md`
- [ ] No AI attribution in any commit message (constitution, Commits and releases)
