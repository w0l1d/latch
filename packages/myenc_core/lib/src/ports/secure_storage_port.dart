import 'dart:typed_data';

abstract interface class SecureStoragePort {
  Future<void> storePassphrase(String keyId, Uint8List passphrase);
  Future<Uint8List?> retrievePassphrase(String keyId);
  Future<void> deletePassphrase(String keyId);
  Future<bool> hasPassphrase(String keyId);
}
