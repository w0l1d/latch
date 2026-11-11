# Contributing

Thanks for looking. Latch is a small, deliberately narrow project: an offline
file-encryption app with no server, no account, and no recovery path. That
narrowness is the product, so the rules below are about protecting it rather
than about style preference.

**Security issues do not go in an issue or a pull request.** See
[`SECURITY.md`](SECURITY.md).

## Before you start

Open an issue first for anything larger than a typo or a small fix. It is much
cheaper to disagree about an approach in an issue than in a review.

Work lands on `develop`; `main` only receives merges from it.

## The three rules that are not negotiable

1. **The `.latch` v1 byte layout is frozen.** [`docs/FORMAT.md`](docs/FORMAT.md)
   is normative. Two freeze guards pin it: `codec_freeze_test.dart` against an
   independently derived hex layout, and the golden vectors in
   `packages/myenc_adapters/test/golden/`, produced by a separate Python
   implementation. **If one of those fails, the layout changed — revert it.**
   Never edit a freeze guard or a golden vector to make a test pass. A real
   format change is a new version byte, with readers failing closed on versions
   they do not know.

2. **No recovery features.** No escrow, no key server, no backdoor, no "reset my
   passphrase". A forgotten passphrase is permanent loss by design, and the app
   says so.

3. **`packages/myenc_core/` stays pure Dart.** No Flutter, no `dart:io`. It is
   the auditable heart of the project and it must remain testable and readable
   in isolation. Platform code belongs in `myenc_adapters` or the app.

## Layout

| Path | Contains |
|---|---|
| `packages/myenc_core/` | Pure Dart: `.latch` codec, envelope service, DEK wrapping, KDF params, typed errors, ports |
| `packages/myenc_adapters/` | Port implementations: libsodium crypto, `dart:io` file I/O |
| `lib/` | The Flutter app; `lib/core/` holds the isolate façade and orchestration |
| `android/` | Kotlin SAF bridge and its JVM unit tests |
| `test/`, `packages/*/test/` | Dart tests |
| `e2e/`, `integration_test/` | Maestro flows and the on-device pipeline test |

## Build and test

The repository is three packages that CI analyzes and tests separately. There
is no single command that runs all of them.

```sh
flutter pub get

# app
dart format --set-exit-if-changed .
flutter analyze --no-pub
flutter test

# core
cd packages/myenc_core && flutter test && flutter analyze --no-pub

# adapters
cd packages/myenc_adapters && flutter test && flutter analyze --no-pub

# Android Kotlin unit tests (no device needed)
cd android && ./gradlew :app:testDebugUnitTest
```

- **Formatting is a CI gate.** Run `dart format .` before committing.
  `./tool/setup-hooks.sh` installs local pre-commit and pre-push hooks that run
  the same checks.
- Flutter is pinned to **3.44.2** in CI.
- Do not install libsodium by hand or set `LD_LIBRARY_PATH`; the `sodium`
  package ships it through Dart native assets.

## Commit and PR style

- [Conventional Commits](https://www.conventionalcommits.org/) with a scope:
  `feat(core):`, `fix(app):`, `build(android):`, `docs:`. Scopes in use include
  `app`, `core`, `encrypt`, `android`.
- One logical change per commit. Say **why** in the body, not just what.
- Reference the issue in the PR description, not in every commit.
- Do not include AI-tool attribution (`Co-Authored-By` trailers for an assistant,
  "Generated with …" lines) in commits, code, or documentation.

The pull request template asks for the test evidence and for a statement about
the frozen format. Please fill it in rather than deleting it.

## License of contributions

Latch is source-available under the terms in [`LICENSE`](LICENSE) — not OSI
open source. By submitting a contribution you agree it is licensed under those
same terms. If that licence does not fit how you want to use the project, that
is a reason not to contribute; it is not something a pull request can change.
