import 'dart:typed_data';
import '../ports/crypto_port.dart';
import '../format/wrap_entry.dart';
import '../format/myenc_errors.dart';

class DekWrap {
  static const int dekLength = 32;
  static const int kekLength = 32;

  // Derives KEK from passphrase+salt, wraps DEK under it, returns a WrapEntry.
  static WrapEntry wrapPassphrase({
    required CryptoPort crypto,
    required Uint8List dek,
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
  }) {
    final kek = crypto.argon2idDerive(
      passphrase: passphrase,
      salt: salt,
      opslimit: opslimit,
      memlimit: memlimit,
      outputLength: kekLength,
    );
    final wrapped = crypto.secretboxSeal(dek, kek);
    return WrapEntry(type: WrapType.passphrase, bytes: wrapped);
  }

  // Unwraps a passphrase WrapEntry to recover the DEK.
  // Throws WrongPassphraseError if the passphrase is wrong.
  static Uint8List unwrapPassphrase({
    required CryptoPort crypto,
    required WrapEntry entry,
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
  }) {
    if (entry.type != WrapType.passphrase) {
      throw CorruptedFileError('expected passphrase wrap entry, got ${entry.type}');
    }
    final kek = crypto.argon2idDerive(
      passphrase: passphrase,
      salt: salt,
      opslimit: opslimit,
      memlimit: memlimit,
      outputLength: kekLength,
    );
    return crypto.secretboxOpen(entry.bytes, kek);
  }

  /// Wraps [dek] under a device-bound symmetric key via secretbox.
  /// The device key is generated once and stored in platform secure storage
  /// (iOS Keychain / Android Keystore), so unwrap only succeeds on this device.
  static WrapEntry wrapDeviceKey({
    required CryptoPort crypto,
    required Uint8List dek,
    required Uint8List deviceKey,
  }) {
    final wrapped = crypto.secretboxSeal(dek, deviceKey);
    return WrapEntry(type: WrapType.hardwareKey, bytes: wrapped);
  }

  /// Unwraps a hardware-key WrapEntry to recover the DEK.
  /// Throws WrongPassphraseError on authentication failure so callers can
  /// distinguish "this key doesn't match" from corruption.
  static Uint8List unwrapDeviceKey({
    required CryptoPort crypto,
    required WrapEntry entry,
    required Uint8List deviceKey,
  }) {
    if (entry.type != WrapType.hardwareKey) {
      throw CorruptedFileError(
          'expected hardware-key wrap entry, got ${entry.type}');
    }
    return crypto.secretboxOpen(entry.bytes, deviceKey);
  }
}
