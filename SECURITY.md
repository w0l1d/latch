# Security policy

Latch is an offline file-encryption tool. A bug in the wrong place here is not a
crash — it is plaintext that should have stayed encrypted, or a passphrase that
should have stayed secret. Please report those privately.

## Reporting a vulnerability

**Use GitHub's private reporting, not a public issue:**

[**Report a vulnerability →**](https://github.com/w0l1d/latch/security/advisories/new)

That channel is visible only to the maintainer. If it is unavailable to you,
open an issue that says only that you have a security report and would like a
private channel — do not put details, proof-of-concept code, or affected files
in it.

### What to include

- **Version.** Settings → About → tap the **Build** row; it copies the tag,
  versionCode, SHA and package name on one line. This is the fastest way to tell
  which binary you tested.
- Platform and device (e.g. Pixel 9, Android 15; or iPhone 14, iOS 18).
- What you observed, what you expected, and the smallest reproduction you have.
- Whether the issue needs a malicious file, a malicious grant, physical access,
  or just a normal user flow.

**Never send real passphrases, unencrypted contents of your own files, or
anything that would let someone open a container you care about.** A synthetic
`.latch` file or a synthetic passphrase demonstrates the issue just as well.

## Scope

In scope:

- The `.latch` container format and its parser (`docs/FORMAT.md` is normative).
- Envelope handling: DEK generation, wrapping, re-wrapping, recipient and
  device-key wraps.
- KDF parameters, salt and nonce handling, and key material lifetime in memory.
- Where key material is stored: secure storage, hardware-key path, quick unlock.
- Android SAF/storage handling where it could write plaintext to the wrong
  place, expose a file to another app, or fail to clean up a temporary file.
- Supply chain: a dependency, action, or build step that could alter a shipped
  artifact.

Out of scope, because they are documented design decisions:

- **Recovery of a forgotten passphrase.** There is no server, no escrow, and no
  backdoor — see the README.
- Offline brute force of a weak passphrase. The threat model states plainly that
  passphrase entropy is the security boundary.
- A rooted or compromised device, malware on an unlocked device, or coercion.
- Plaintext that was never given to Latch (a copy made before encryption).

## Supported versions

The latest published release. Latch has no LTS branch — a fix ships as a new
release, and older binaries are not patched.

## What to expect

This is a single-maintainer project without a bug bounty. Reports are read and
acknowledged on a best-effort basis; a confirmed issue is fixed before it is
described publicly. You will be credited in the release notes if you would like
to be.
