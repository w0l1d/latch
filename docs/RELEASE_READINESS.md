# Latch Release Readiness Audit

**Audit date:** 2026-07-12
**Scope:** `lib/`, `android/app/src/main/`, `ios/Runner/Info.plist`, `pubspec.yaml`
**App version:** 1.0.0+1

---

## Priority legend

| Label | Meaning |
|---|---|
| **Blocker** | Must fix before release — app crash, data loss, or store rejection |
| **Should-fix** | Degrades UX or violates platform guidelines — fix before release if practical |
| **Nice-to-have** | Polish, maintenance, defensive hardening |

---

## 1. Store Compliance

### 1.1 iOS: Missing encryption export compliance key

**Blocker** — `ios/Runner/Info.plist`

The app uses XChaCha20-Poly1305, Argon2id, and X25519 for file encryption. These are non-exempt encryption algorithms under US EAR. Apple requires `ITSAppUsesNonExemptEncryption` in `Info.plist` if the app uses encryption beyond what is built into the OS (HTTPS, Keychain, etc.). Without this key, App Store Connect will reject the binary during export compliance review.

Add to `Info.plist`:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Set to `false` if the app qualifies for the exemption (encryption is "limited to authentication, digital signing, or the protection of the user's own data" — this app qualifies). If Apple's reviewer disagrees during review, you may need to set it to `true` and provide an annual self-classification report, but the key must be present either way.

### 1.2 Android: Missing `allowBackup` attribute

**Should-fix** — `android/app/src/main/AndroidManifest.xml`

The manifest does not declare `android:allowBackup`. On Android 12+ (API 31+), the default is `true`, meaning the app's data directory (SharedPreferences, databases) is included in Android Auto Backup. Although `FlutterSecureStorage` uses `EncryptedSharedPreferences` (excluded from backup by Android's key-value backup agent), any future addition of `SharedPreferences` or local files could leak secrets to Google Drive.

Add to the `<application>` element:

```xml
android:allowBackup="false"
```

Alternatively, if you want to allow backup for non-sensitive data, set `android:allowBackup="true"` and add `android:fullBackupContent="@xml/backup_rules"` with an XML file that excludes `EncryptedSharedPreferences` explicitly. The simpler approach for a security app: disable entirely.

### 1.3 iOS: Face ID usage description — present

**OK** — `ios/Runner/Info.plist:91-92`

`NSFaceIDUsageDescription` is present with a proper purpose string. Required for `local_auth` plugin biometric authentication.

### 1.4 iOS: .latch document type — present

**OK** — `ios/Runner/Info.plist:56-90`

`CFBundleDocumentTypes` and `UTImportedTypeDeclarations` are configured for the `.latch` extension with correct UTI `com.latch.latch.latchfile`. The `CFBundleTypeRole` is set to `Editor` (appropriate for an encryption app that rewrites the file and outputs plaintext).

### 1.5 Android: File association intent filter

**Should-fix** — `android/app/src/main/AndroidManifest.xml:30-40`

The `.latch` file association uses `pathPattern=".*\\.latch"` with `mimeType="application/octet-stream"`. The `pathPattern` only matches `file://` URIs; most Android share-sheet and Files-app intents use `content://` URIs, which `pathPattern` cannot match. The `mimeType` fallback (octet-stream) is the actual mechanism users will hit, but it may conflict with any other app that registers for `application/octet-stream`.

No fix is required — this is a known Android limitation (content URIs carry no extension). The `mimeType` match is correct. Document this behavior in release notes.

### 1.6 Android: Permissions

**OK** — No permissions declared in `AndroidManifest.xml`. The app does not use the internet, camera, microphone, contacts, or location. This is correct for an offline file encryption tool.

### 1.7 Data safety / privacy questionnaire

The code confirms: all data stays on-device. There are no network calls, no analytics SDKs, no crash reporters, no third-party services.

- **Collected/shared:** Nothing. No user data leaves the device.
- **Stored locally:** Encrypted passphrases (`FlutterSecureStorage` → iOS Keychain / Android EncryptedSharedPreferences), device key (same), recipient key pairs (same), KDF calibration settings (`SharedPreferences` — not encrypted, but non-sensitive integers), address book labels + public keys (`FlutterSecureStorage`).
- **Temporary data:** Plaintext passphrases are zeroed after use (`pw.fillRange()` in `app_crypto.dart:116,183,244-245,302`). Plaintext file content never persists — it is streamed through the crypto pipeline.
- **Google Play Data Safety section:** Should declare "No data collected or shared."

---

## 2. Accessibility

### 2.1 Missing Semantics on GestureDetector-as-button (8 locations)

**Should-fix** — Multiple files

Eight `GestureDetector` widgets with `onTap` handlers lack any `Semantics` wrapper. Screen reader users (TalkBack / VoiceOver) cannot discover these as tappable controls. Critical paths affected:

| File | Lines | Context |
|---|---|---|
| `lib/features/encrypt/encrypt_options_screen.dart` | 144–180 | Output folder chooser row |
| `lib/features/encrypt/encrypt_options_screen.dart` | 199–246 | Two radio-style option cards ("Keep originals" / "Delete originals") |
| `lib/features/encrypt/encrypt_passphrase_screen.dart` | 190–212 | Three passphrase-source chips ("Type it" / "From app" / "Password mgr") |
| `lib/features/encrypt/encrypt_passphrase_screen.dart` | 118–155 | "Save for quick unlock" toggle row |
| `lib/features/encrypt/encrypt_pick_screen.dart` | 52–90 | Empty-state "Choose files" area |
| `lib/features/encrypt/encrypt_pick_screen.dart` | 161–164 | Remove-file icon (close button) |
| `lib/features/decrypt/decrypt_passphrase_screen.dart` | 142–173 | "Use quick unlock instead" tile |
| `lib/features/decrypt/decrypt_pick_screen.dart` | 46–106 | File pick area |
| `lib/features/settings/change_passphrase_screen.dart` | 140–168 | File picker area |
| `lib/features/settings/passphrase_storage_screen.dart` | 74–119 | Three storage-mode radio cards |
| `lib/features/settings/secure_delete_screen.dart` | 192–219 | File picker area |
| `lib/features/settings/add_recipient_screen.dart` | 160–189 | File picker area |
| `lib/features/onboarding/loss_moment_screen.dart` | 59–87 | Checkbox label row (also has redundant dual handler — both `GestureDetector.onTap` and `Checkbox.onChanged` toggle state, potentially confusing assistive tech focus tracking) |

**Suggested fix:** Wrap each `GestureDetector` used as a button with:

```dart
Semantics(
  button: true,
  label: 'Choose files to lock',
  child: GestureDetector(onTap: _pickFiles, child: ...),
)
```

For the radio cards, use `Semantics(checked: isSelected, label: 'Keep the originals', child: ...)`. For the chip group, consider replacing with `ChoiceChip` widgets which carry built-in semantics. For the checkbox row, remove the outer `GestureDetector` and let `Checkbox.onChanged` be the sole toggle; use `MergeSemantics` to link the label to the checkbox.

### 2.2 Fixed font sizes that bypass system text scaling (12 locations)

**Should-fix** — Multiple files

These literal `fontSize` values ignore the system text-scaling accessibility setting. Users who need larger text see no change:

| File | Line | Value | Context |
|---|---|---|---|
| `lib/features/encrypt/encrypt_passphrase_screen.dart` | 105 | 17dp | Passphrase TextField |
| `lib/features/encrypt/encrypt_passphrase_screen.dart` | 113 | 13dp | Password strength label |
| `lib/features/encrypt/encrypt_passphrase_screen.dart` | 203,205,208 | 13dp | Source chip labels |
| `lib/features/encrypt/encrypt_success_screen.dart` | 95–96 | 14dp | Output file name |
| `lib/features/decrypt/decrypt_passphrase_screen.dart` | 138 | 17dp | Passphrase TextField |
| `lib/features/decrypt/decrypt_success_screen.dart` | 59 | 14dp | Restored file path |
| `lib/features/decrypt/decrypt_success_screen.dart` | 62 | 12dp | "Ready to open" label |
| `lib/features/settings/change_passphrase_screen.dart` | 176,185 | 17dp | Passphrase TextFields |
| `lib/features/settings/add_recipient_screen.dart` | 197 | 17dp | Passphrase TextField |
| `lib/features/settings/sharing_keys_screen.dart` | 86,202 | 13dp | Hex key input and public key display |
| `lib/features/onboarding/how_it_works_screen.dart` | 85 | 16dp | Step number in circle |
| `lib/features/onboarding/loss_moment_screen.dart` | 38 | 26dp | Exclamation text in circle |

**Suggested fix:** Use `Theme.of(context).textTheme.*` for standard text, and for custom sizes use `Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: ...)` — Material 3 Text widgets automatically apply `MediaQuery.textScaler` unless you set a literal `fontSize` inside a `TextStyle` that lacks a `TextScaler` override. Alternatively, wrap the widget in a `MediaQuery` that adjusts based on the system scale factor.

### 2.3 WCAG AA contrast failures (3 color pairs)

**Should-fix** — `lib/shared/theme/app_theme.dart:4–17`

| Foreground | Background | Ratio | WCAG AA (4.5:1) | Used in |
|---|---|---|---|---|
| `subtle` #9A948A | `background` #F5F3EF | **2.71:1** | ❌ FAIL | `bodySmall` text throughout the app (tertiary labels, hints) |
| `caution` #C98A2E | `cautionLight` #FBF3E4 | **2.66:1** | ❌ FAIL | LatchAlert caution tone — title text and body text on alert background |
| `safe` #3A8A6D | `safeLight` #EAF5F0 | **3.73:1** | ❌ FAIL (normal text) / ⚠️ PASS (large text, ≥18pt bold or ≥24pt) | LatchAlert danger tone — title text on alert background |

The `subtle` color is used for `bodySmall` (13dp) — this is the most widespread failure, affecting every screen that shows secondary hints. The `caution` alert background makes body text hard to read precisely when the user most needs clarity (a warning alert).

**Suggested fix:**
- `subtle` → darken to at least `#7D7870` (≈4.5:1 on background) or `#6B665D` (= `muted`, 5.14:1)
- `caution` on `cautionLight` → darken caution to at least `#8B5A0E` or lighten `cautionLight` to pure white
- `safe` on `safeLight` → darken safe to at least `#2D6B54` or lighten body text color

### 2.4 Undersized touch targets (2 locations)

**Should-fix**

| File | Lines | Size | Context |
|---|---|---|---|
| `lib/features/encrypt/encrypt_passphrase_screen.dart` | 190–212 | ~27dp height | Source chips ("Type it", "From app", "Password mgr"). Each chip has `vertical: 7` padding + ~13dp font height ≈ 27dp total. Well below 48dp minimum. |
| `lib/features/encrypt/encrypt_pick_screen.dart` | 161–164 | ~24dp | Remove-file close icon. Plain `Icon(Icons.close)` (24dp default size) with zero padding, no `IconButton` wrapper. Half the required 48dp touch target. |

**Suggested fix:** For chips, increase padding to `EdgeInsets.symmetric(horizontal: 14, vertical: 14)` (minimum 48dp height). For the remove icon, wrap in an `IconButton` or add `constraints: BoxConstraints(minWidth: 48, minHeight: 48)` with `padding: EdgeInsets.all(12)`.

### 2.5 Progress indicator missing semantics label

**Nice-to-have** — `lib/features/onboarding/device_check_screen.dart:111–119`

`LinearProgressIndicator` with no `semanticsLabel`. Screen readers announce a generic "progress bar" without context. Should add `semanticsLabel: 'Benchmarking device performance'` and `semanticsValue: '${(_progress * 100).round()} percent'`.

### 2.6 Decorative icons not excluded from semantics (4 locations)

**Nice-to-have**

| File | Line | Icon |
|---|---|---|
| `lib/features/home/home_screen.dart` | 28 | `Icons.lock_outline` (decorative) |
| `lib/features/onboarding/welcome_screen.dart` | 47–61 | `Icons.lock_outline` (thematic, borderline) |
| `lib/features/onboarding/ready_screen.dart` | 22–25 | `Icons.check` (decorative — text below conveys meaning) |

Wrap purely decorative icons in `ExcludeSemantics`. For thematic icons (welcome screen), add `Semantics(label: 'Lock icon')`.

---

## 3. Performance

### 3.1 Crypto on main isolate — PASS

**OK** — All crypto runs in worker isolates

All Argon2id KDF, XChaCha20-Poly1305 encrypt/decrypt, and X25519 key generation run inside `Isolate.spawn(latchWorker, ...)` (see `lib/core/isolate_worker.dart`). The main isolate only does:
- `SharedPreferences` reads (KDF params): `app_crypto.dart:42-43`
- `Random.secure()` CSPRNG for key generation: `device_key_service.dart:29`, `passphrase_storage_service.dart:153`
- Passphrase strength heuristics (character counting): `crypto_stub.dart:15-36`

The device benchmark screen (`device_check_screen.dart:50-93`) runs Argon2id on the UI thread intentionally to measure user-perceived cost. This is a one-time calibration during onboarding and does not freeze for more than ~150ms per iteration (8 attempts), but it does block UI. This is a deliberate design choice — document it.

### 3.2 Whole-file I/O — PASS (with caveat)

**OK** — No `readAsBytes()` or `writeAsBytes()` found on user file data

The codebase uses streaming I/O via `io.openRead()` and `io.writeChunked()` for all file encryption/decryption. Two locations read up to 128 KiB into memory for header parsing:

- `lib/core/key_id_resolver.dart:31-34` — reads up to 128 KiB to parse `.latch` header
- `lib/core/crypto_erase.dart:32-33,50` — reads/writes up to 128 KiB for header erase

For files smaller than 128 KiB, this buffers the entire file. This is acceptable (the header must be parsed in full), but note that a 1-byte `.latch` file with a valid header would result in a 128 KiB buffer allocation. Should add a `min(len, K)` guard to avoid excessive allocation for tiny files. Not a release blocker.

### 3.3 Progress screen rebuild pressure

**Should-fix** — Progress screens and passphrase screens

| File | Lines | Issue |
|---|---|---|
| `lib/features/encrypt/encrypt_progress_screen.dart` | progress stream listener | The progress `Stream<double>` fires for every chunk (potentially hundreds of events per file). Each event triggers `setState` → full widget rebuild. The `LinearProgressIndicator` re-renders each time. |
| `lib/features/decrypt/decrypt_progress_screen.dart` | same pattern | Same streaming progress → setState per chunk. |
| `lib/features/settings/change_passphrase_screen.dart` | 174,183 | `onChanged: (_) => setState(() {})` — full rebuild on every keystroke |
| `lib/features/settings/add_recipient_screen.dart` | 195 | Same keystroke rebuild |

The progress screen rebuilds are more significant: each chunk (default 64 KiB) fires a progress update. For a 1 GiB file, this is ~16,384 `setState` calls. While the progress bar itself is a lightweight widget, the full `Scaffold` + `Column` + text labels are rebuilt each time.

**Suggested fix:** Throttle progress updates to at most 10/sec in the progress screen widget. For passphrase `onChanged`, move `_busy`/`_ready` state into a `ValueNotifier` instead of `setState`. Not a release blocker for typical file sizes but will cause visible jank on large files.

---

## 4. Robustness

### 4.1 Raw exception messages shown to users (3 locations)

**Blocker** — Multiple files

| File | Line | Issue |
|---|---|---|
| `lib/features/encrypt/encrypt_progress_screen.dart` | 127 | `'Encryption failed: $e'` — raw exception string interpolated into user-visible dialog. Any non-`StorageFullError` exception leaks its `.toString()` (type names, file paths, internal details). |
| `lib/features/decrypt/decrypt_progress_screen.dart` | 83 | `e.toString()` passed to `_showError('Decryption failed', ...)` — same issue. |
| `lib/features/decrypt/decrypt_progress_screen.dart` | 129 | `r.errorMessage ?? "error"` — partial-success error message may carry internal text. |

**Suggested fix:** Map known exception types to user-friendly messages:

```dart
String _userMessage(Object e) => switch (e) {
  StorageFullError() => 'Not enough storage space.',
  WrongPassphraseError() => 'Incorrect passphrase.',
  NotALatchFileError() => 'This file is not a .latch file.',
  CorruptedFileError() => 'This file appears to be damaged.',
  VersionTooNewError() => 'This file requires a newer version of Latch.',
  _ => 'An unexpected error occurred.',
};
```

### 4.2 PopScope `canPop: false` without handler (4 locations)

**Blocker** — Multiple files

`PopScope(canPop: false)` with no `onPopInvokedWithResult` callback completely disables the Android system back gesture/button with zero feedback. Users are trapped on these screens:

| File | Lines | Context |
|---|---|---|
| `lib/features/encrypt/encrypt_progress_screen.dart` | 159–160 | During active encryption — user cannot back out even to cancel (Cancel button exists but is easy to miss) |
| `lib/features/encrypt/encrypt_success_screen.dart` | 13–14 | Terminal success state — user stuck until they tap a button |
| `lib/features/decrypt/decrypt_progress_screen.dart` | 190–191 | During active decryption — same issue |
| `lib/features/decrypt/decrypt_success_screen.dart` | 13–14 | Same terminal-state trap |

For the progress screens, this is particularly bad: if the isolate hangs or the operation stalls, the user has no escape other than force-killing the app. On the success screens, the user can only exit via one of the two action buttons.

**Suggested fix:** Add `onPopInvokedWithResult`:

```dart
// Progress screens:
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, _) {
    if (!didPop) {
      _cancel(); // trigger existing cancel logic
    }
  },
  child: ...,
)

// Success screens:
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, _) {
    if (!didPop) context.go('/home');
  },
  child: ...,
)
```

### 4.3 Unhandled init crash in main.dart

**Blocker** — `lib/main.dart:11-17`

```dart
await AppCrypto.init();  // no try-catch
```

If `SodiumSumoInit.init()` fails (native library load failure, unsupported platform), the app crashes before `runApp()` with no error UI. The user sees a native crash dialog or white screen.

**Suggested fix:**
```dart
try {
  await AppCrypto.init();
} catch (e) {
  runApp(MaterialApp(
    home: Scaffold(
      body: Center(child: Text('Failed to initialize encryption engine.\n\n$e')),
    ),
  ));
  return;
}
```

### 4.4 Unhandled calibration crash in device_check_screen

**Blocker** — `lib/features/onboarding/device_check_screen.dart:31`

`final calibrated = await _calibrate();` with no try-catch. If sodium init fails or Argon2id throws, the exception propagates unhandled to the Flutter framework → red error screen or app crash. This is the very first screen after onboarding starts — a crash here means the user cannot proceed.

**Suggested fix:** Wrap `_calibrate()` in try-catch; fall back to safe defaults (opslimit=2, memlimit=65536) and show a non-blocking warning.

### 4.5 Unsafe type casts in router (8 routes)

**Should-fix** — `lib/core/router.dart:38,45,56,69,82,90,97,106`

Pattern `state.extra as Map<String, dynamic>? ?? {}` casts without `is` check. If any route is pushed with a non-Map `extra`, the cast throws `TypeError` at runtime. While all current call sites pass the correct types, this is fragile.

**Suggested fix:** Use `state.extra is Map<String, dynamic> ? (state.extra as Map<String, dynamic>) : {}`. Same pattern for `List<String>`.

### 4.6 Double-pop navigation pattern (3 locations)

**Should-fix** — Multiple files

| File | Lines | Pattern |
|---|---|---|
| `lib/features/settings/change_passphrase_screen.dart` | 91,113 | `Navigator.pop(context); context.pop();` |
| `lib/features/settings/secure_delete_screen.dart` | 145–146 | Same |
| `lib/features/settings/add_recipient_screen.dart` | 113–114 | Same |

This assumes a dialog is on the Navigator stack above the route. If the dialog was already dismissed (edge case: rapid double-tap on the alert button), the first `pop` removes the route, and the second `pop` navigates one level too far (potentially exiting the app if at root).

**Suggested fix:** Use `Navigator.pop(context)` once to dismiss the dialog, then `context.pop()` to exit the route. Ensure the alert's `onPressed` does both in the correct order, but guard against double-execution:

```dart
if (Navigator.of(context).canPop()) {
  Navigator.pop(context); // dismiss dialog
}
context.pop(); // pop route
```

### 4.7 Race condition in add_recipient_screen

**Should-fix** — `lib/features/settings/add_recipient_screen.dart:73-74`

`_recipients.firstWhere((r) => r.label == _selectedLabel)` throws `StateError` if `_selectedLabel` is no longer in the list (edge case: recipient deleted between `_loadRecipients` and `_run` — possible if another screen or background operation removes the entry). The `_ready` guard only checks `_selectedLabel != null`, not membership.

**Suggested fix:** Use `.firstWhere(..., orElse: () => null)` and handle null.

### 4.8 Passphrase storage screen is a functional stub

**Should-fix** — `lib/features/settings/passphrase_storage_screen.dart:51-53`

The "Save choice" button calls `context.pop()` without persisting the selected `_StorageMode`. The user's choice is lost on navigation. This screen appears to be a placeholder for future functionality but is exposed to users via the Settings screen.

**Suggested fix:** Either persist the choice to `SharedPreferences` and read it on load, or remove/hide the screen from settings navigation until the feature is implemented.

### 4.9 Hardcoded version string

**Should-fix** — `lib/features/settings/settings_screen.dart:203`

`_InfoTile(title: 'Version', value: '1.0.0')` is a hardcoded string. It will go out of sync with `pubspec.yaml` on the next version bump.

**Suggested fix:** Use the `package_info_plus` package or a build-time constant:

```dart
import 'package:package_info_plus/package_info_plus.dart';
// In state:
final info = await PackageInfo.fromPlatform();
// Display:
_InfoTile(title: 'Version', value: '${info.version}+${info.buildNumber}'),
```

### 4.10 Secret key zeroization on main isolate

**Nice-to-have** — `lib/features/settings/sharing_keys_screen.dart:37`

`kp.secretKey.fillRange(0, kp.secretKey.length, 0)` runs synchronously on the main isolate. For a 32-byte key this is negligible, but the pattern is worth noting: if the key buffer grows, this becomes a UI-blocking operation. Should be fine for current key sizes.

### 4.11 Error-handling gap: missing try-catch in settings load

**Nice-to-have** — `lib/features/settings/settings_screen.dart:51-75`

`_load()` calls `SharedPreferences.getInstance()` and `svc.list()` without try-catch. If storage is unavailable (e.g., device encryption policy change), the widget crashes. Most Android/iOS devices will not hit this, but it's a defensive gap.

### 4.12 String-based error classification

**Nice-to-have** — `lib/features/decrypt/decrypt_progress_screen.dart:107-123`

Error type classification via `msg.contains('WrongPassphraseError')` is brittle. If error message formatting changes, all classifications silently fall through to the generic `else` branch.

**Suggested fix:** Use error codes or sealed classes instead of string matching. If the current architecture uses string error codes from the isolate, switch to an enum/union type in the isolate's message protocol.

---

## 5. Additional Observations

### 5.1 Golden vector testing — PASS

The `.latch` format is backed by independent golden vectors (`packages/myenc_adapters/test/golden/`) produced by `tool/gen_golden_vectors.py` (argon2-cffi + libsodium via ctypes). The format spec (`docs/FORMAT.md`) is normative and frozen as of 2026-07-12.

### 5.2 Crypto hygiene — PASS

- Passphrase bytes are zeroed after use (`app_crypto.dart:116,183,244-245,302`)
- Secret keys in secure storage use platform-backed encryption (iOS Keychain / Android EncryptedSharedPreferences)
- No plaintext file content is persisted to disk
- `secure_delete_screen.dart` implements crypto-erase (overwrites header with random bytes before deleting)

### 5.3 Threat model coverage — PASS

Per `docs/FORMAT.md §11`: known limitations are documented (header not bound as AD, file-size leakage, key-id hint visible). No undocumented security gaps found.

### 5.4 Crypto isolation — PASS

All heavy crypto runs in worker isolates. The main thread only handles UI and trivial operations (SharedPreferences reads, CSPRNG keygen, strength heuristics).

### 5.5 Data exfiltration — PASS

No network calls, no analytics, no third-party SDKs, no HTTP clients. All persistent storage is on-device via `FlutterSecureStorage`. The only external channel is the OS share-intent plugin (`receive_sharing_intent`) which is inbound-only.

---

## 6. Release Checklist

Ordered, actionable. Complete before submitting to stores.

- [ ] **1.** Add `ITSAppUsesNonExemptEncryption` to `ios/Runner/Info.plist` (§1.1)
- [ ] **2.** Add `android:allowBackup="false"` to `AndroidManifest.xml` (§1.2)
- [ ] **3.** Replace raw exception messages in `encrypt_progress_screen.dart:127` and `decrypt_progress_screen.dart:83,129` with user-friendly messages (§4.1)
- [ ] **4.** Add `onPopInvokedWithResult` to all 4 `PopScope(canPop: false)` screens (§4.2)
- [ ] **5.** Add try-catch around `AppCrypto.init()` in `main.dart:12` with fallback error UI (§4.3)
- [ ] **6.** Add try-catch around `_calibrate()` in `device_check_screen.dart:31` with safe defaults (§4.4)
- [ ] **7.** Add `Semantics` wrappers to 13+ `GestureDetector`-as-button widgets (§2.1)
- [ ] **8.** Replace fixed font sizes with theme-derived styles or add `TextScaler` support at 12 locations (§2.2)
- [ ] **9.** Fix 3 WCAG AA contrast failures — darken `subtle`, `caution`, and `safe` colors (§2.3)
- [ ] **10.** Increase touch targets on source chips (27dp → 48dp) and remove-file icon (24dp → 48dp) (§2.4)
- [ ] **11.** Fix unsafe casts in `router.dart` — use `is` checks before casting (§4.5)
- [ ] **12.** Fix double-pop navigation in 3 screens — guard with `canPop()` checks (§4.6)
- [ ] **13.** Replace hardcoded version string in `settings_screen.dart:203` with `package_info_plus` (§4.9)
- [ ] **14.** Either persist `StorageMode` choice in `passphrase_storage_screen.dart` or hide screen (§4.8)
- [ ] **15.** Fix `.firstWhere` race condition in `add_recipient_screen.dart:73` (§4.7)
- [ ] **16.** Prepare Google Play Data Safety section — "No data collected or shared" (§1.7)
- [ ] **17.** Add `semanticsLabel` to device benchmark `LinearProgressIndicator` (§2.5)
- [ ] **18.** (Optional) Throttle progress-screen `setState` updates to ≤10/sec (§3.3)
- [ ] **19.** (Optional) Transition error type classification from string matching to sealed classes (§4.12)

---

## Summary of Top Findings

1. **iOS encryption export compliance key missing** (`Info.plist`) — App Store rejection risk
2. **4 PopScope screens trap users** with no back-gesture handler — Android UX regression
3. **Raw exception strings in user-facing dialogs** (`e.toString()`) — 3 locations in encrypt/decrypt progress
4. **No try-catch on `AppCrypto.init()`** in `main.dart` — crash before any UI renders
5. **No try-catch on `_calibrate()`** in `device_check_screen.dart` — crash on first onboarding screen
6. **13+ `GestureDetector` widgets lack `Semantics`** — completely invisible to TalkBack/VoiceOver
7. **3 WCAG AA contrast failures** — `subtle` (2.71:1), `caution` (2.66:1), `safe` (3.73:1) text unreadable
8. **12 fixed `fontSize` values** ignore system text-scaling accessibility setting
9. **8 unsafe type casts in `router.dart`** — runtime `TypeError` if route extras are wrong type
10. **`passphrase_storage_screen.dart` is a stub** — user's storage-mode choice is not persisted
