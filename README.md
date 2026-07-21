<div align="center">

# 🔒 Latch

### Stateless, offline file encryption for your phone.

Encrypt any file with a passphrase into a self-contained `.latch` container that opens on any device with the same passphrase — **no account, no cloud, no server, no per-file records.**

[![CI](https://github.com/w0l1d/latch/actions/workflows/ci.yml/badge.svg)](https://github.com/w0l1d/latch/actions/workflows/ci.yml)
![Flutter](https://img.shields.io/badge/Flutter-3.44.2-02569B?logo=flutter&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-3DDC84?logo=android&logoColor=white)
![Crypto](https://img.shields.io/badge/crypto-libsodium-8A2BE2)
![Status](https://img.shields.io/badge/status-work%20in%20progress-orange)

*Your files, encrypted on your device, with no one in the loop — not even us.*

</div>

---

## Why Latch

People keep sensitive files on phones that are easily lost, stolen, or silently backed up somewhere they don't control. Cloud "secure storage" asks you to trust a provider and a network. Your phone's own disk encryption protects the *device* — but not a file the moment it's copied, shared, or synced.

Latch protects the **file itself, wherever it travels.** Encrypt it once and it stays opaque on an SD card, in an email attachment, or synced to any cloud — openable only with your passphrase, with nothing stored on any server.

Latch behaves as a pure function: **`(file, passphrase) → file`**. No account. No telemetry. No recovery path.

> ⚠️ **A forgotten passphrase means permanent, unrecoverable loss.** That is the design, not a bug — there is no recovery server because there is no server.

## Features

- 🔐 **Passphrase encryption** — lock any file into a `.latch` container built on audited [libsodium](https://libsodium.org) primitives.
- 📦 **Batch operations** — encrypt or decrypt many files at once; one failure never aborts the rest.
- 🔁 **Change passphrase cheaply** — re-wraps the ~32-byte data key only; the file body is never re-encrypted.
- 👥 **Share with recipients** — wrap a file to someone's X25519 public key so they can open it with their private key, no shared account.
- 🧨 **Secure delete (crypto-erase)** — destroy the key material and the body becomes permanent noise, regardless of flash remnants.
- 👆 **Quick unlock** — optional biometric / PIN gate over a hardware-backed store, or autofill from your own password manager. The PIN is never a KDF input.
- 📂 **Outputs land in the source file's own folder** — even under Android scoped storage, via a Play-compliant SAF folder grant (no "All files access").
- 📴 **Fully offline & stateless** — no network permission needed to do the one thing it does.

## How it works — envelope encryption

Every file is locked with its own random 32-byte **data-encryption key (DEK)**. The DEK is then *wrapped* by one or more key-encryption keys:

```
                    ┌─ passphrase-derived key (Argon2id)   ← always
   random DEK ──────┼─ device hardware key (optional)      ← quick-unlock
        │           └─ recipient X25519 public key (opt.)  ← sharing
        │
        └─ encrypts ─▶ file body  (XChaCha20-Poly1305 secretstream, chunked & authenticated)
```

- The **body** is encrypted once with the DEK and is immutable for the life of the file.
- Changing a passphrase, adding a device wrap, sharing with a recipient, or crypto-erasing only ever touches the **header** — never the body.
- The `.latch` file is **fully self-describing**: every KDF parameter, salt, and wrap travels in the header, so decryption needs nothing but the file and the passphrase — on any device, any fresh install.

**Fail-closed guarantees:** a wrong passphrase fails instantly at the wrap, *before* the body is ever touched. A corrupt or tampered file fails at a chunk authentication tag. Decryption **never emits partial or garbage plaintext.**

See [`docs/FORMAT.md`](docs/FORMAT.md) for the normative, frozen `.latch` v1 byte layout and versioning policy, and [`project_spec.md`](project_spec.md) for the full design specification and threat model.

## Threat model (in brief)

**Protects against** a lost or stolen device, leaked copies synced/emailed/copied elsewhere, and recovery of deleted plaintext (via crypto-erase).

**Does _not_ protect against** malware on an unlocked running device, a compromised/rooted OS, coercion, or **weak passphrases** — with the device in hand an attacker brute-forces offline at full speed, so passphrase entropy and Argon2id cost are the entire security boundary. These limits are stated plainly to the user in-app.

## Architecture

Hexagonal (ports & adapters), split into three independently analyzed and tested packages:

```
latch/
├── packages/
│   ├── myenc_core/       # pure Dart — .latch codec, envelope service, ports, typed errors.
│   │                     # NO Flutter, NO dart:io. The auditable heart.
│   └── myenc_adapters/   # concrete adapters: libsodium crypto + streaming dart:io file I/O
└── lib/                  # Flutter app: onboarding, encrypt/decrypt flows, settings, isolates
```

- The **core** has zero Flutter / `dart:io` dependency — it's the small, portable, auditable surface where all the cryptography lives.
- All heavy crypto (Argon2id KDF, secretstream) runs in a **background isolate** so the UI never blocks.
- The `.latch` v1 wire format is **frozen** and guarded by two independent test suites (a byte-layout freeze test and end-to-end golden vectors produced by a separate Python reference implementation).

## Getting started

**Prerequisites:** Flutter **3.44.2** (Dart SDK `^3.12.2`).

```sh
git clone https://github.com/w0l1d/latch.git
cd latch
flutter pub get          # at root; resolves the path-dependency packages too
flutter run              # on a connected device / emulator
```

> `libsodium` ships automatically via the `sodium` package's Dart native assets — do **not** `apt install libsodium` or set `LD_LIBRARY_PATH`.

### Tests & analysis

The three packages are analyzed and tested independently (exactly what CI does):

```sh
# app (root)
flutter analyze --no-pub
flutter test

# per package
cd packages/myenc_core     && flutter test && flutter analyze --no-pub
cd packages/myenc_adapters && flutter test && flutter analyze --no-pub

# a single test
flutter test test/foo_test.dart
flutter test --plain-name "expr"
```

## Roadmap

| Phase | Ships | Status |
|---|---|:--:|
| **M0** | Workspace, package split, `sodium` wired, CI + test harness | ✅ |
| **M1** | Core codec, envelope service, ports, unit + golden-vector tests | ✅ |
| **M2** | MVP: passphrase encrypt/decrypt, streaming + isolate, tamper errors, onboarding | ✅ |
| **M3** | Stored passphrase + biometric/PIN gate, autofill, key-id resolution, batch | ✅ |
| **M4** | Hardware wrap (Keystore/Enclave) as optional additive wrap, quick-unlock | ✅ |
| **M5** | Sharing via X25519 recipient wraps | ✅ |
| **M6** | Parser fuzzing, KDF tuning, metadata options, accessibility, store crypto declarations | 🚧 |

See `project_spec.md` §11 for the full roadmap.

## Contributing

Issues and pull requests are welcome. A few house rules the codebase enforces:

- **The `.latch` v1 format is frozen.** To extend it, bump the version byte — readers must fail closed on unknown versions. Freeze-guard tests are not editable to make a change pass.
- Keep `packages/myenc_core` free of Flutter and `dart:io` imports.
- Preserve the wrong-passphrase-vs-corrupt-file distinction and the "never emit partial plaintext" guarantee in any crypto change.
- Commits follow **Conventional Commits** with a scope (`feat(core):`, `fix(app):`, `build(android):`, `docs:`).

## License

**Not yet licensed.** Until a `LICENSE` file is added, all rights are reserved by the author. If you'd like to use or contribute to the code, please open an issue to discuss.

---

<div align="center">
<sub>Built with Flutter · libsodium · Argon2id · XChaCha20-Poly1305 · X25519</sub>
</div>
