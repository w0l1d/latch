# Testing gotchas — FakeAsync vs isolates (agent notes)

Read this before writing or debugging any test that spawns the crypto worker, touches real file I/O, or drives a progress screen.

`testWidgets` runs under a fake clock. Anything needing the **real** Dart event loop hangs inside it and leaves a dangling ReceivePort that hangs teardown.

- Spawning the crypto worker isolate (`AppCrypto.*Files().listen()`, i.e. the encrypt/decrypt **progress** screens) is not reliably drivable from `flutter test`. Crypto completion + the "last result before final 1.0" invariant the progress screens depend on are pinned instead by `test/app_crypto_batch_test.dart` (plain `test()`, real event loop, real isolate).
- `await Directory.delete(recursive:)` and other real async file I/O in a `testWidgets` body also hang. Use the **sync** variants in widget tests: `Directory.systemTemp.createTempSync(...)`, `file.deleteSync(...)`.
- In a `testWidgets`, do real-async/isolate work inside `tester.runAsync(() async {...})` so it runs on the real loop, then `pumpAndSettle()` for the resulting setState/navigation. See `test/e2e_flow_test.dart` (which drives every button/navigation screen but the progress screens).
- Importing a transitive platform interface (`*_platform_interface`) in tests is normal here; add it to root `dev_dependencies` to satisfy `depend_on_referenced_packages`.
- Folder screens under `testWidgets` need a tall viewport: `tester.view.physicalSize = const Size(800, 2600)` with `devicePixelRatio = 1`, or the placement section pushes rows off-screen.
- Real-isolate bulk behaviour lives in `test/app_crypto_bulk_test.dart` (plain `test()`, sync file APIs), not in the widget tests.
- Kotlin SAF pieces (`ExternalStorageDocIds`, `DocumentPathResolver`, `SubPathSegments`) are JVM tests under `android/app/src/test/kotlin/...`, run by `cd android && ./gradlew :app:testDebugUnitTest` (or CI's `android-unit-test` job). They are framework-free by design so they need no emulator.
- `test/architecture_test.dart` (spec 005, when landed) machine-checks laws A1/A3/A4/A5/A6/A9 from `docs/ARCHITECTURE.md` and runs in the root test job.
