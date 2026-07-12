import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// An X25519 keypair used for recipient sharing (spec §3, wrap 0x03).
typedef ShareKeypair = ({Uint8List publicKey, Uint8List secretKey});

/// One saved recipient in the address book.
class RecipientEntry {
  final String label;
  final String publicKeyHex;
  final DateTime createdAt;

  const RecipientEntry({
    required this.label,
    required this.publicKeyHex,
    required this.createdAt,
  });
}

/// Manages this install's X25519 sharing keypair and the recipient address
/// book, both in platform secure storage (iOS Keychain / Android
/// EncryptedSharedPreferences).
///
/// Keypair generation needs libsodium, which is only initialized inside
/// worker isolates — so the generator is injected ([keygen], wired to
/// AppCrypto.generateShareKeypair by main()). Tests inject a fake generator
/// and never touch isolates.
class RecipientKeyService {
  static const _pkTag = 'latch_share_pk';
  static const _skTag = 'latch_share_sk';
  static const _metaKey = 'latch_recipients_meta';
  static const _keyLength = 32;

  static final _hexKeyPattern = RegExp(r'^[0-9a-f]{64}$');

  final FlutterSecureStorage _storage;

  /// Generates a fresh X25519 keypair; wired to
  /// AppCrypto.generateShareKeypair by main(), faked in tests.
  final Future<ShareKeypair> Function()? keygen;

  RecipientKeyService({
    FlutterSecureStorage? storage,
    this.keygen,
  }) : _storage = storage ?? const FlutterSecureStorage();

  // ---- my keypair -----------------------------------------------------------

  /// Returns this install's sharing keypair, generating and persisting it on
  /// first call.
  Future<ShareKeypair> getOrCreateKeyPair() async {
    final pkHex = await _storage.read(key: _pkTag);
    final skHex = await _storage.read(key: _skTag);
    if (pkHex != null &&
        skHex != null &&
        _hexKeyPattern.hasMatch(pkHex) &&
        _hexKeyPattern.hasMatch(skHex)) {
      return (publicKey: _hexDecode(pkHex), secretKey: _hexDecode(skHex));
    }

    final generate = keygen;
    if (generate == null) {
      throw StateError(
          'RecipientKeyService has no keypair generator configured');
    }
    final kp = await generate();
    await _storage.write(key: _pkTag, value: _hexEncode(kp.publicKey));
    await _storage.write(key: _skTag, value: _hexEncode(kp.secretKey));
    return kp;
  }

  /// True once a sharing keypair has been generated and stored.
  Future<bool> hasKeyPair() async {
    final pkHex = await _storage.read(key: _pkTag);
    final skHex = await _storage.read(key: _skTag);
    return pkHex != null &&
        skHex != null &&
        _hexKeyPattern.hasMatch(pkHex) &&
        _hexKeyPattern.hasMatch(skHex);
  }

  /// The stored public key as hex, for showing / copying. Null until a
  /// keypair exists.
  Future<String?> publicKeyHex() async {
    final pkHex = await _storage.read(key: _pkTag);
    if (pkHex == null || !_hexKeyPattern.hasMatch(pkHex)) return null;
    return pkHex;
  }

  /// Deletes the sharing keypair — files shared TO this install can no
  /// longer be opened via the recipient wrap after this.
  Future<void> deleteKeyPair() async {
    await _storage.delete(key: _pkTag);
    await _storage.delete(key: _skTag);
  }

  // ---- recipient address book ----------------------------------------------

  /// Saves a recipient's public key under [label]. An existing label is
  /// overwritten with the new key.
  ///
  /// Throws [ArgumentError] unless [publicKeyHex] is exactly 64 hex chars
  /// (a 32-byte X25519 public key).
  Future<void> storeRecipient(String label, String publicKeyHex) async {
    final normalized = publicKeyHex.trim().toLowerCase();
    if (!_hexKeyPattern.hasMatch(normalized)) {
      throw ArgumentError.value(publicKeyHex, 'publicKeyHex',
          'must be 64 hex characters (a 32-byte X25519 public key)');
    }
    final meta = await _readMeta();
    meta.removeWhere((m) => m['label'] == label);
    meta.add({
      'label': label,
      'publicKey': normalized,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _storage.write(key: _metaKey, value: jsonEncode(meta));
  }

  /// Lists saved recipients.
  Future<List<RecipientEntry>> listRecipients() async {
    return (await _readMeta()).map((m) {
      return RecipientEntry(
        label: m['label'] as String,
        publicKeyHex: m['publicKey'] as String,
        createdAt: DateTime.parse(m['createdAt'] as String),
      );
    }).toList();
  }

  /// Removes the recipient saved under [label]. No-op if absent.
  Future<void> deleteRecipient(String label) async {
    final meta = await _readMeta();
    final before = meta.length;
    meta.removeWhere((m) => m['label'] == label);
    if (meta.length == before) return;
    await _storage.write(key: _metaKey, value: jsonEncode(meta));
  }

  // ---- internal -------------------------------------------------------------

  static String _hexEncode(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(_keyLength);
    for (var i = 0; i < _keyLength; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _readMeta() async {
    final raw = await _storage.read(key: _metaKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}

/// Decodes a 64-hex-char public key into 32 bytes; used by callers that hold
/// address-book entries. Throws [ArgumentError] on malformed input.
Uint8List decodePublicKeyHex(String hex) {
  final normalized = hex.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(hex, 'hex', 'must be 64 hex characters');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
