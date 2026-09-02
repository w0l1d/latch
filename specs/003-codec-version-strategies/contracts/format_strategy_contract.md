# Contract: Format Version Strategy

The interface between the `MyencCodec` façade and the per-version header parsers. This is the
single seam a future format version plugs into.

## Public surface (unchanged)

```dart
(FileHeader, int) MyencCodec.decodeHeader(Uint8List bytes);
Uint8List          MyencCodec.encodeHeader(FileHeader header);
```

No consumer changes. The record `(header, consumed)` and every thrown error type are as today.

## Strategy contract (new)

```dart
abstract interface class FormatVersionStrategy {
  (FileHeader, int) decode(Uint8List bytes, int offset);
  Uint8List encode(FileHeader header);
}
```

## Rules

1. **Purity** — strategies are pure functions: no randomness, no I/O, no platform
   dependencies. Deterministic: identical inputs → identical outputs (FR-004/005).
2. **Offset contract** — `decode` receives the offset *after* the version-independent prefix
   (magic + version byte) and returns `consumed` relative to `bytes` as passed to the public
   entry point. The façade owns prefix arithmetic; strategies own their layout from the first
   version-specific byte.
3. **Errors** — strategies throw the existing typed `LatchError` family only. For v1, the exact
   error for each input is frozen (FR-009): same input, same error, before and after the
   refactor.
4. **Fail-closed** — a failed decode throws; it never returns partial data, and it never emits
   partial plaintext. A version byte not in the registry never reaches a strategy: the façade
   gate (`FormatVersionRegistry.require`) rejects it first.
5. **Dispatch** — keyed by `FormatVersion` entries (never raw integers). Totality: the dispatch
   table's key set equals the registry's entry set, both directions (FR-003).
6. **Rewrap path** — `changePassphrase` / `addRecipient` re-encode through the public
   `encodeHeader`; the version byte and version-specific fields survive byte-identically
   (FR-008). No code path encodes through a strategy directly.
7. **Registry purity** — the registry gains no knowledge of this contract; it remains version
   decisions only (FR-011). Capability fields (BL-001) arrive on `FormatVersion` entries and
   key the same dispatch — this contract does not move when they land.

## Compliance tests

- `format_strategy_v1_test.dart` — v1's exhaustive battery against the strategy (FR-012).
- Totality test — registry vs dispatch table, both directions (FR-003).
- Rewrap round-trip test — version byte + version-specific fields byte-identical (FR-008).
- Header corpus + compatibility corpus tests — neutrality (FR-005/006/007).
- `codec_freeze_test.dart` + golden vectors — untouched, the acceptance criterion (FR-009).
