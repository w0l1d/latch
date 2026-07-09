# Project Specification — Stateless Local File Encryption App

**Status:** Final design specification, ready for build.
**Working names (placeholders):** *the app* for the product, **`.myenc`** for the encrypted file format.
**Chosen stack:** Flutter (Dart) + libsodium via `sodium_libs`, hexagonal architecture, thin native channel for the optional hardware wrap.

---

## 1. Executive summary

The app encrypts and decrypts files directly on the user's phone using a passphrase, producing self-contained encrypted files with a custom extension. It is **local-first, offline, and stateless about files**: the encrypted file is the single source of truth, and the app behaves as a pure function — `(file, passphrase) → file` — keeping no server, no account, no cloud, and no per-file records.

The cryptographic design is **envelope encryption**: every file is locked with its own random data key (DEK), and the DEK is itself wrapped by one or more key-encryption keys (a passphrase-derived key, optionally a device hardware key, optionally a recipient's public key). This single design serves every goal — lost-phone protection, cheap passphrase changes, multiple unlock paths, crypto-erase, and future sharing — without ever re-encrypting the file body.

---

## 2. Business description

### 2.1 Problem & value proposition
People hold sensitive files on phones that are easily lost, stolen, or backed up to places they don't control. Cloud "secure storage" requires trusting a provider and a network; the OS's own encryption protects the device but not a file once it's copied, shared, or synced. The app gives the user **portable, provider-independent encryption they fully control**: encrypt a file once, and it stays opaque anywhere it travels, openable only with the passphrase, with nothing stored on any server.

The core promise: *your files, encrypted on your device, with no one in the loop — not even us.*

### 2.2 Target users
- **Primary:** privacy-conscious individuals protecting personal documents (IDs, financial records, private media) against a lost or stolen phone.
- **Secondary:** people who need to hand an encrypted file to someone else without a shared cloud account (enabled by the optional sharing feature).
- Assume general consumers, not security experts: the app must make the safe path the default and explain risk plainly.

### 2.3 Positioning & differentiation
- **vs cloud vaults (Dropbox/iCloud "secure" folders):** no provider trust, no account, works offline, file stays encrypted after it leaves the app.
- **vs built-in OS encryption:** OS encryption protects the *device*; the app protects the *file* wherever it goes.
- **vs developer tools (age, GPG, Cryptomator):** a focused, consumer-friendly mobile experience built on the same proven crypto, without container mounts or command lines.

The differentiator is the combination: **proven envelope crypto + truly stateless/offline + a calm consumer UX.**

### 2.4 Business model (options — to decide, no data monetization either way)
Because the product's entire premise is that nothing leaves the device, monetization must not depend on data. Options:
1. **One-time paid app** — simplest, aligns with a "tool you own" identity.
2. **Freemium** — free single-file encrypt/decrypt forever; paid tier unlocks convenience (stored passphrases, batch, sharing).
3. **Open-source core + optional paid "pro" / donations** — strongest trust story for a security product; the auditable core builds credibility.

A privacy-first product benefits most from transparency, so an open or source-available core (option 3) reinforces the value proposition.

### 2.5 Success criteria (privacy-respecting)
Measured without inspecting file contents or names: install/retention, completion rate of the encrypt and decrypt flows, onboarding completion (including the data-loss acknowledgement), crash-free sessions, and review/word-of-mouth sentiment around trust. No content telemetry.

### 2.6 Non-goals
No cloud sync, no accounts, no server-side key escrow, no DRM, no advertising, no content telemetry, no file-manager/library ambitions. The app does one thing well.

---

## 3. Threat model

### Protects against
- **Lost or stolen device** (primary): a locked or powered-off phone yields only ciphertext.
- **Leaked copies:** a `.myenc` synced to cloud, copied to an SD card, or emailed stays opaque without the passphrase.
- **Recovery of deleted plaintext remnants:** handled in combination with OS full-disk/file-based encryption and crypto-erase semantics — *not* by overwriting storage (impossible on flash).

### Does NOT protect against (state explicitly to the user)
- Malware or a hostile actor on an **unlocked, running** device while files are decrypted.
- A **compromised or rooted/jailbroken OS**.
- **Weak passphrases.** With the device in hand, an attacker brute-forces the passphrase **offline at full speed** — no server rate-limits them. Passphrase entropy and KDF cost are the entire boundary.
- **Coercion.**
- Live forensic extraction of plaintext currently in memory.

---

## 4. Use cases

Actor, preconditions, flow, postcondition, edges. (Screen design is owned by the UI/UX brief.)

### UC-1 — Encrypt a file
- **Pre:** a file; a passphrase (typed/stored/autofilled).
- **Flow:** select file → supply passphrase → generate random DEK → encrypt body (chunked AEAD) → derive KEK (Argon2id) → wrap DEK → write `.myenc` (header + ciphertext).
- **Post:** `.myenc` exists; original optionally deleted (off by default).
- **Edges:** very large files (stream, never whole-load); low storage; cancel mid-run (no partial output); name collision.

### UC-2 — Decrypt a file
- **Pre:** valid `.myenc`; correct passphrase.
- **Flow:** select `.myenc` → read header → derive KEK → unwrap DEK → verify + decrypt chunks → write plaintext.
- **Post:** plaintext restored.
- **Edges:** wrong passphrase (UC-4); truncated/corrupt; unknown newer version; output collision.

### UC-3 — Batch encrypt / decrypt
Multiple files in one operation; each gets its **own** random DEK; per-file success/failure reported; one failure doesn't abort the rest.

### UC-4 — Wrong passphrase / tamper detection
Wrong passphrase fails at wrap-unwrap (authenticated) before the body is touched → instant clear "wrong passphrase." Correct passphrase but failed chunk tag → "corrupted or tampered." Never returns partial/garbage plaintext (fail closed).

### UC-5 — Change passphrase
Re-derive a new KEK and **re-wrap the same DEK** (~32 bytes); body not re-encrypted. Verify old passphrase first.

### UC-6 — Add a recipient / share *(optional, later phase)*
Wrap the existing DEK to a recipient's public key (X25519 sealed box); add it to the file; recipient decrypts with their private key. Body not re-encrypted.

### UC-7 — Biometric / PIN quick-unlock *(optional)*
Store a passphrase in the hardware-backed store, gated by biometric/PIN. The gate releases the passphrase; **the PIN is never a KDF input.**

### UC-8 — External password manager
Passphrase lives in the user's own manager (Bitwarden, Samsung Pass, iCloud Keychain) via OS autofill; the app stores nothing.

### UC-9 — Multiple stored passphrases
An opaque random **key-id** in the header identifies *which* passphrase to use (revealing nothing about it), so the right one is selected instantly instead of trying each (Argon2id is deliberately slow).

### UC-10 — Secure delete (crypto-erase)
"Securely delete" by destroying the DEK/wraps; the body becomes permanent noise regardless of flash remnants. Reliable only if no unwrapped DEK or extra wrap copy was persisted elsewhere.

### UC-11 — Cross-device / fresh-install open
A `.myenc` decrypts on any device or fresh install with only the passphrase (all parameters travel in the file). Files protected *solely* by a hardware wrap are intentionally non-portable.

### UC-12 — First-run setup
Device self-benchmark to pick the highest Argon2id cost that stays responsive; an unmissable statement that **a forgotten passphrase means permanent, unrecoverable data loss.**

---

## 5. Flows

### 5.1 Envelope lifecycle (the heart of the system)
```
ENCRYPT:  random DEK ── encrypts ──> file body (chunked AEAD)
          passphrase ── Argon2id ──> KEK ── wraps ──> DEK   (stored as a wrap)

DECRYPT:  passphrase ── Argon2id ──> KEK ── unwraps ──> DEK ── decrypts ──> body
```
- Multiple wraps of the same DEK = multiple unlock paths (passphrase / hardware / recipient).
- Change passphrase = re-wrap DEK only. Share = add a wrap. Secure delete = destroy wraps.

### 5.2 Passphrase-source flow (security identical in all three; only convenience differs)
```
type each time ─────────────► nothing stored on device (most secure)
app vault ──► biometric/PIN gate ──► hardware-backed store releases passphrase
external manager ──► OS autofill ──► manager fills passphrase (app stores nothing)
```

### 5.3 Success / failure flow
```
unwrap DEK  ─ fails ─► "Wrong passphrase"           (instant; body untouched)
            ─ ok ───► decrypt chunks
                       chunk tag fails ─► "Corrupted or tampered file"
                       all tags ok + FINAL seen ─► success
```

### 5.4 First-run flow
Honest intro → unmissable data-loss acknowledgement (no reset, by design) → brief background performance benchmark → ready.

---

## 6. Settings

| Setting | Options / behavior | Default |
|---|---|---|
| KDF cost (Argon2id) | Auto-tuned by device benchmark; advanced manual ops/memory override | Auto |
| Cipher | AES-256-GCM / ChaCha20-Poly1305, auto by hardware | Auto |
| Passphrase storage | None / app hardware-backed vault / external manager | None |
| Quick-unlock gate | Off / biometric / device PIN (gate only) | Off |
| Delete original after encrypt | Off / on (with flash-remnant warning) | Off |
| Encrypt original filename | Store real name inside header | On |
| Output location | User-chosen via system picker | Ask each time |
| File extension / association | `.myenc` (configurable); register to open in app | `.myenc` |
| Streaming chunk size | 64 KB – 1 MB | 256 KB |
| Auto-lock / clear | Clear in-memory secrets + quick-unlock session after inactivity | Short timeout |

---

## 7. Security constraints (hard rules)

1. **Authenticated encryption only** (AES-256-GCM, ChaCha20-Poly1305, or libsodium `secretstream`). No unauthenticated modes.
2. **Use an audited library; never roll your own crypto** (libsodium via `sodium_libs`).
3. **Argon2id** for passphrase→key (scrypt fallback; PBKDF2 only if forced); parameters benchmarked per device.
4. **Per-file random DEK**, never derived from the passphrase; KEKs only ever *wrap* it.
5. **PIN is a gate, never a KDF input.**
6. **Hardware wrap is additive, never sole** — a passphrase wrap is always present and sufficient (portability + no owner lockout).
7. **Never persist secrets in the clear** — `SecureKey` buffers; passphrases as overwritable bytes; no plaintext temp files; no secrets in logs.
8. **Self-describing, versioned header** — magic, version, KDF id+params, cipher id, chunk size, key-id, wrap list. Versioning enables crypto-agility.
9. **No passphrase hash, no canary plaintext** — the AEAD tag is the correctness signal.
10. **Chunked streaming with cross-chunk integrity** — per-chunk auth + counter + FINAL marker (anti-reorder/truncation); never whole-file loads.
11. **Unique nonces per key** (guaranteed by `secretstream`).
12. **Fail closed** — any auth failure returns nothing; never partial plaintext.
13. **Crypto-erase discipline** — don't scatter key copies; one self-contained artifact to delete.
14. **Lost passphrase = permanent loss** — communicated unmissably; any recovery key is opt-in and is itself just another wrap.
15. **Minimize metadata leakage** — optionally encrypt the filename; note that size still leaks (padding is a future option).

---

## 8. `.myenc` v1 file format

Binary, self-describing, versioned. Multi-byte integers **big-endian**. The full header is bound to the body as associated data, so header tampering breaks decryption.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 5 | Magic | ASCII `MYENC` — real type id (extension is cosmetic) |
| 5 | 1 | Version | `0x01` |
| 6 | 1 | Flags | bit0 = filename encrypted; rest reserved |
| 7 | 1 | KDF id | `0x01` = Argon2id |
| 8 | 2 | Salt length | uint16 (=16) |
| 10 | 16 | KDF salt | random per file |
| 26 | 4 | Argon2 opslimit | uint32 |
| 30 | 4 | Argon2 memlimit | uint32 (KiB) |
| 34 | 1 | Cipher id | `0x01` = XChaCha20-Poly1305 secretstream |
| 35 | 4 | Chunk size | uint32 |
| 39 | 16 | Key-id hint | opaque random label |
| 55 | 1 | Wrap count | uint8 (≥1) |
| 56 | … | Wrap list | repeated (below) |
| … | 2 | Enc-filename length | uint16, only if flags bit0 |
| … | … | Enc filename | AEAD ciphertext of original name |
| … | 24 | secretstream header | libsodium stream state |
| … | … | Encrypted chunks | ciphertext + 16-byte tag each; last carries FINAL tag |

**Each wrap:** `type` (1B: 1=passphrase, 2=hardware, 3=recipient) · `length` (2B) · `bytes` (SecretBox/sealed-box of the 32-byte DEK, incl. nonce).

- Wrong passphrase fails at its wrap entry, instantly. Correct-but-corrupt fails at a chunk tag. Distinguishable for free.
- Adding/revoking a wrap edits the wrap list only; the body is never re-encrypted.

---

## 9. Architecture & technology

**Hexagonal (ports & adapters). Dependency rule: everything points inward to a pure core.**

- **Domain core (pure Dart):** envelope logic, `.myenc` codec, DEK/wrap orchestration. No Flutter, no `dart:io`, no plugins — only `dart:typed_data` and the libsodium *interface*. Independently unit-testable; the part to audit.
- **Ports:** `CryptoPort`, `FileIoPort`, `SecureStoragePort`, `HardwareKeyPort`, `BiometricPort`, `FilePickerPort`.
- **Adapters:** concrete implementations swappable without touching the core.
- **Presentation:** Flutter UI + state, driving the core via application services.

**Stack rationale (Flutter + libsodium):** performance is not a differentiator (crypto runs in native C regardless), so the decisive factors are binding quality, secure-hardware access, and codebase economy. Flutter gives one codebase in one approachable language while `sodium_libs` provides the *real* audited libsodium via FFI. The only true two-platform surface is the optional hardware wrap, handled by a small native channel. The pure core preserves a clean migration path to a Rust/age-based engine later if maximal auditability is ever required.

### Project structure
```
app/
├─ packages/
│  ├─ myenc_core/          # pure Dart: format/ envelope/ ports/ errors/  + tests
│  └─ myenc_adapters/      # crypto_sodium, file_io, secure_storage,
│                          # hardware_wrap, biometric, picker
└─ lib/                    # Flutter app: features/ + composition root (DI)
android/  ios/             # native MethodChannel impls (hardware wrap)
```

### Port → adapter / package mapping
| Port | Package |
|---|---|
| CryptoPort | `sodium_libs` (pwhash Argon2id, SecretBox, secretstream, sealed box) |
| FileIoPort | `dart:io` + `file_picker` (chunked streaming) |
| SecureStoragePort | `flutter_secure_storage` |
| HardwareKeyPort | custom `MethodChannel` (Keystore/StrongBox + Secure Enclave) |
| BiometricPort | `local_auth` |
| Password manager | OS Autofill hints |
| State / workspace | `riverpod` (or `bloc`) · `melos` |

### Key flows (engineering)
- **Encrypt:** random DEK → derive KEK (Argon2id, fresh salt) → wrap DEK → write header → secretstream init (header as AAD) → stream chunks, last = FINAL → atomic temp→rename. Runs in an **isolate**; progress reported.
- **Decrypt:** strict header decode (fail-closed) → resolve KEK → unwrap DEK (fail here = wrong passphrase) → secretstream init → pull chunks (fail = corrupt) → require FINAL → atomic write.
- **Change passphrase / share / secure-delete:** operate on the DEK/wraps only.
- **Concurrency:** all heavy work in isolates; strict chunked streaming; cancellation leaves no partial output.

---

## 10. Testing strategy

- **Known-answer (golden) vectors** for the codec, verified against an independent reference (e.g. a Python libsodium script) to catch endian/offset bugs before any UI.
- **Round-trip property tests** over random files/sizes/passphrases.
- **Negative tests:** wrong passphrase, flipped byte, truncation (missing FINAL), tampered header — each maps to the correct typed error.
- **Parser fuzzing:** malformed headers always fail closed, never crash or guess.
- **Cross-device / cross-version** decrypt; **large-file / isolate / cancellation** tests.

---

## 11. Roadmap

| Phase | Ships |
|---|---|
| **M0 — Setup** | Workspace, package split, `sodium_libs` wired, CI + test harness |
| **M1 — Core + format** | Codec, envelope service, ports, full unit + golden-vector tests (no UI) |
| **M2 — MVP** | Passphrase-only encrypt/decrypt of single files; streaming + isolate; wrong-passphrase/tamper errors; onboarding data-loss warning |
| **M3 — Convenience** | Stored passphrase + biometric/PIN gate; external-manager autofill; key-id resolution; batch |
| **M4 — Hardware wrap** | Native channel (Keystore/Enclave) as optional additive wrap; quick-unlock |
| **M5 — Sharing (optional)** | X25519 recipient wraps |
| **M6 — Hardening** | Parser fuzzing, KDF benchmark tuning, metadata options, accessibility, store crypto declarations |

---

## 12. Risks & mitigations

- **Hardware-wrap native code** — only true two-platform surface; keep tiny behind `HardwareKeyPort`; ship M2 without it.
- **Dart string immutability** — take passphrases as byte buffers, minimize lifetime, use `SecureKey` for derived material.
- **Large-file memory/battery** — strict chunked streaming.
- **Format mistakes** — golden vectors + independent reference before any UI.
- **Plugin/binding drift** — pin versions; the pure core + ports make adapter swaps (or a Rust migration) contained.

---

## 13. Open decisions

- Argon2 cost floor/ceiling for the benchmark (the actual numbers are the whole security boundary).
- Whether sharing (M5) is in scope for v1.
- Business model selection (§2.4) and whether the core is open-source.
- `.myenc` size-padding policy (defer to M6 unless required earlier).