import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// One stored passphrase entry.
class StoredPassphrase {
  final String label;
  final String passphrase;
  final DateTime createdAt;

  /// Hex of the opaque random 16-byte key-id written into the header of files
  /// encrypted with this passphrase (spec UC-9). Random — derived from nothing
  /// — so it reveals nothing about the passphrase; it only links a file to
  /// this stored entry.
  final String keyIdHex;

  const StoredPassphrase({
    required this.label,
    required this.passphrase,
    required this.createdAt,
    required this.keyIdHex,
  });
}

/// Persists passphrases in platform secure storage (iOS Keychain / Android
/// EncryptedSharedPreferences) and gates retrieval behind biometric or
/// device-credential authentication via local_auth.
class PassphraseStorageService {
  static const _prefix = 'latch_kp_';
  static const _metaKey = '${_prefix}meta'; // JSON list of {label, createdAt}

  final FlutterSecureStorage _storage;
  final LocalAuthentication _auth;

  PassphraseStorageService({
    FlutterSecureStorage? storage,
    LocalAuthentication? auth,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _auth = auth ?? LocalAuthentication();

  // ---- public API -----------------------------------------------------------

  /// Whether the device can check biometrics or fall back to PIN/pattern.
  Future<bool> get canAuthenticate => _auth.isDeviceSupported();

  /// Whether any passphrases are currently stored.
  Future<bool> hasStored() async {
    final meta = await _readMeta();
    return meta.isNotEmpty;
  }

  /// Lists stored entries (without their passphrases — the secret stays in
  /// secure storage until [loadWithAuth] is called).
  Future<List<StoredPassphrase>> list() async {
    return (await _readMeta()).map((m) {
      return StoredPassphrase(
        label: m['label'] as String,
        passphrase: '', // never returned by list()
        createdAt: DateTime.parse(m['createdAt'] as String),
        keyIdHex: (m['keyId'] as String?) ?? '',
      );
    }).toList();
  }

  /// Returns the label of the entry whose key-id matches [keyIdHex], or null.
  /// Used to resolve which stored passphrase a .latch header points at.
  Future<String?> findLabelByKeyId(String keyIdHex) async {
    if (keyIdHex.isEmpty) return null;
    final meta = await _readMeta();
    for (final m in meta) {
      if (m['keyId'] == keyIdHex) return m['label'] as String;
    }
    return null;
  }

  /// Persists [passphrase] under [label] and returns the entry's key-id (hex).
  /// If [label] already exists it is overwritten with the new passphrase but
  /// KEEPS its key-id — files already encrypted under that id must still
  /// resolve to this entry.
  Future<String> store(String label, String passphrase) async {
    final meta = await _readMeta();
    String? keyIdHex;
    final existing = meta.indexWhere((m) => m['label'] == label);
    if (existing >= 0) {
      keyIdHex = meta[existing]['keyId'] as String?;
      meta.removeAt(existing);
    }
    keyIdHex ??= _randomKeyIdHex();

    // Next key = max existing index + 1 — meta.length would collide after a
    // delete (store a,b → delete a → store c would reuse b's key and silently
    // overwrite b's passphrase).
    var maxIdx = -1;
    for (final m in meta) {
      final idx = int.tryParse((m['key'] as String).substring(_prefix.length));
      if (idx != null && idx > maxIdx) maxIdx = idx;
    }
    final key = '$_prefix${maxIdx + 1}';
    meta.add({
      'label': label,
      'key': key,
      'keyId': keyIdHex,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _storage.write(key: _metaKey, value: jsonEncode(meta));
    await _storage.write(key: key, value: passphrase);
    return keyIdHex;
  }

  /// Presents the system biometric / device-credential dialog, then — if the
  /// user authenticates — reads and returns the stored passphrase for [label].
  ///
  /// Returns `null` when the user cancels or fails authentication.
  Future<String?> loadWithAuth(String label) async {
    final meta = await _readMeta();
    final entry = meta.firstWhere(
      (m) => m['label'] == label,
      orElse: () => <String, dynamic>{},
    );
    if (entry.isEmpty) return null;

    final ok = await _auth.authenticate(
      localizedReason: 'Unlock your passphrase for "$label"',
      sensitiveTransaction: true,
    );
    if (!ok) return null;

    return _storage.read(key: entry['key'] as String);
  }

  /// Deletes the stored passphrase for [label].
  Future<void> delete(String label) async {
    final meta = await _readMeta();
    final idx = meta.indexWhere((m) => m['label'] == label);
    if (idx < 0) return;
    final entry = meta.removeAt(idx);
    await _storage.delete(key: entry['key'] as String);
    await _storage.write(key: _metaKey, value: jsonEncode(meta));
  }

  /// Removes all stored passphrases.
  Future<void> deleteAll() async {
    final meta = await _readMeta();
    for (final e in meta) {
      await _storage.delete(key: e['key'] as String);
    }
    await _storage.delete(key: _metaKey);
  }

  // ---- internal -------------------------------------------------------------

  static String _randomKeyIdHex() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
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
