## What & why

<!-- What changes, and the problem it solves. Link the issue if there is one. -->

## How it was verified

<!-- The commands you ran and what they printed. "Tests pass" is not evidence. -->

- [ ] `dart format --set-exit-if-changed .`
- [ ] `flutter analyze --no-pub` — app, `myenc_core`, `myenc_adapters`
- [ ] `flutter test` — app, `myenc_core`, `myenc_adapters`
- [ ] `./gradlew :app:testDebugUnitTest` — if anything under `android/` changed

## Frozen-format checklist

- [ ] No byte of the `.latch` v1 layout changed — **or** a new version byte was
      added, `docs/FORMAT.md` was updated, and readers fail closed on the old
      version
- [ ] No freeze guard or golden vector was edited to make a test pass
- [ ] No recovery-style feature was added (escrow, key server, passphrase reset)

## Review notes

<!-- Where a reviewer should look twice: native code, key material lifetime,
     an isolate message, a Gradle guard, a scheduled workflow. Write "none"
     if there is genuinely nothing. -->
