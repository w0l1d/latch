# Latch — Privacy Policy

**Effective date:** 10 November 2026
**App:** Latch (`com.latch.latch`) — offline file encryption for Android and iOS
**Developer:** Walid Ahdouf

## The short version

Latch does not collect your data. There is no account, no server, and no analytics. Your
files, your passphrase and your keys never leave your device except where you personally
send them. The app's network permission is not present at all, so it could not transmit
anything even if a future bug told it to.

Everything below explains that in detail, and everything below is checkable: the source
code is public at <https://github.com/w0l1d/latch>.

## What Latch does not do

- **No account or sign-in.** Latch has no servers and no user database.
- **No network access.** The release build's manifest declares no `INTERNET` permission.
  Android enforces the absence of a network permission at the OS level — the app has no
  socket it can open. (Debug builds built by developers from the public source do include
  `INTERNET`, because the Flutter tooling requires it; those builds are never distributed.)
- **No analytics, telemetry, crash reporting or advertising.** There is no Firebase,
  Sentry, Crashlytics, analytics SDK, A/B testing framework, or ad library in the app.
- **No tracking identifiers.** Latch does not read your advertising ID, device ID, IMEI,
  contacts, location, camera, microphone, calendar or call logs.
- **No cloud backup of app data.** `android:allowBackup="false"` is set, so Android does
  not copy Latch's private storage into Google's backup service.

## What stays on your device

### Your files

Latch only reads a file after you select it in the system file picker, and only writes the
result to the destination you choose. It does not scan, index, or enumerate your storage.

While processing a file, Latch writes a temporary `<name>.tmp` file next to the output and
removes it when processing finishes or is cancelled. For decryption that temporary file can
contain partially decrypted plaintext, which is why it is always swept on cancellation.

### Your passphrase

You can optionally save your passphrase so you don't have to retype it. If you do, it is
stored in the platform's encrypted credential storage — Android Keystore-backed encrypted
storage, or the iOS Keychain — never in a plain file. You can gate access to it with
biometrics or your device credential, and you can delete stored passphrases individually or
all at once from Settings → Passphrase storage.

Latch never transmits your passphrase anywhere, and cannot recover it for you. **A lost
passphrase means the encrypted file is unrecoverable. This is deliberate.**

### Your keys

- **Device key:** the optional hardware-bound wrap uses a key generated inside the Android
  Keystore / iOS Secure Enclave. The key material never leaves secure hardware.
- **Recipient keys:** private keys you create for people who share files with you are kept
  in the same secure storage. Public keys are designed to be shared — that is the point of
  them. If you copy a public key to the clipboard from Settings, it is a public key, not a
  secret.

### Your settings

Preferences — your save folders, output location, and toggles such as
delete-originals-after-encrypt — are stored locally in the app's private storage.

## What is inside a `.latch` file

Anyone holding a `.latch` file can see a small amount of unencrypted metadata: the format
version, the key-derivation parameters, and a short key-identifier hint used to pick the
right key. The file's contents, and the key that unlocks it, are encrypted with
XChaCha20-Poly1305. **The original filename is not stored in the container.**

## When data leaves your device

Only when you send it. If you share a `.latch` file, it travels through whatever app you
picked in Android's share sheet — email, chat, cloud drive — under that app's privacy
terms. Latch itself does not upload anything. The recipient still needs the passphrase,
which Latch never includes.

## Children

Latch collects no personal data from anyone, including children. It is not directed at
children under 13, and there is nothing to collect because there is no collection at all.

## Security

The encryption design is documented in [`docs/FORMAT.md`](docs/FORMAT.md) and the
implementation is public. Corrections and audit findings are welcome through the issue
tracker. No system is perfectly secure, and Latch makes no such claim.

## Deleting your data

- Encrypted and decrypted files stay where you put them until you delete them with your
  file manager.
- Clearing Latch's app data, or uninstalling it, erases the stored passphrase, keys and
  settings. Uninstalling does **not** delete your files.
- Because there is no server, there is nothing for us to delete on your behalf.

## Changes to this policy

If this policy changes, the new version is published at this URL with a new effective date.
Because Latch has no way to contact you, the repository's release notes are where a change
would be announced.

## Contact

Questions or concerns: open an issue at <https://github.com/w0l1d/latch/issues>.
