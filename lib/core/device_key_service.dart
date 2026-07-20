import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages a device-bound symmetric key stored in platform secure storage
/// (iOS Keychain / Android Keystore). The key is generated once per install
/// and used to create additional DEK wraps so files can be opened on this
/// device even if the passphrase is forgotten (spec §Device-bound recovery).
///
/// Key generation uses [Random.secure] (the OS CSPRNG) on the main isolate —
/// the same source PassphraseStorageService uses for key-ids — so no sodium
/// instance is needed outside the crypto worker isolates.
class DeviceKeyService {
  static const _keyTag = 'latch_device_key';
  static const _keyLength = 32;

  final FlutterSecureStorage _storage;

  DeviceKeyService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Returns the device-bound key, creating it if it doesn't exist.
  /// The key is 32 random bytes stored as hex in platform secure storage.
  Future<Uint8List> getOrCreateKey() async {
    final raw = await _storage.read(key: _keyTag);
    if (raw != null && raw.length == _keyLength * 2) {
      return _hexDecode(raw);
    }
    final rng = Random.secure();
    final key = Uint8List.fromList(
      List.generate(_keyLength, (_) => rng.nextInt(256)),
    );
    await _storage.write(key: _keyTag, value: _hexEncode(key));
    return key;
  }

  /// True once a device key has been generated and stored.
  Future<bool> hasKey() async {
    final raw = await _storage.read(key: _keyTag);
    return raw != null && raw.length == _keyLength * 2;
  }

  /// Deletes the device key — after this, hardware-key wraps in existing files
  /// can no longer be unwrapped on this device.
  Future<void> deleteKey() => _storage.delete(key: _keyTag);

  static String _hexEncode(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(_keyLength);
    for (var i = 0; i < _keyLength; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
