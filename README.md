# Latch

Stateless, offline file encryption for your phone. Encrypt any file with a passphrase; the encrypted file is self-contained and opens on any device with the same passphrase — no account, no cloud, no server, no per-file records.

**Core promise:** *your files, encrypted on your device, with no one in the loop — not even us.*

## How it works

Latch uses **envelope encryption** built on audited [libsodium](https://libsodium.org) primitives:

- Every file gets its own random 32-byte data key (DEK).
- The file body is encrypted with the DEK using XChaCha20-Poly1305 `secretstream` (chunked, authenticated, truncation-proof).
- The DEK is *wrapped* by a key derived from your passphrase (Argon2id).
- The `.latch` file is fully self-describing: all KDF parameters, salts, and wraps travel in the header, so decryption needs nothing but the file and the passphrase.

Wrong passphrase fails instantly at the wrap (before the body is touched); a corrupt or tampered file fails at a chunk tag. Decryption never emits partial plaintext.

**A forgotten passphrase means permanent, unrecoverable loss.** That is the design, not a bug — there is no recovery server because there is no server.

## Architecture

Hexagonal (ports & adapters), with a pure Dart core:

```
packages/
  myenc_core/       # pure Dart: .latch codec, envelope service, ports, typed errors
  myenc_adapters/   # sodium crypto adapter, dart:io streaming file I/O
lib/                # Flutter app: onboarding, encrypt/decrypt flows, settings
```

The core has no Flutter or dart:io dependency — it is the independently testable, auditable heart of the app. See `project_spec.md` for the full design specification and threat model, and [`docs/FORMAT.md`](docs/FORMAT.md) for the normative, frozen `.latch` v1 file format (byte layout, validation rules, versioning policy).

## Development

```sh
flutter pub get
flutter test packages/myenc_core
flutter test packages/myenc_adapters
flutter run
```

## Status

Work in progress — see `project_spec.md` §11 for the roadmap.
