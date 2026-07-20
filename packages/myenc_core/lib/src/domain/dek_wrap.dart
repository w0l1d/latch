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
      throw CorruptedFileError(
        'expected passphrase wrap entry, got ${entry.type}',
      );
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
        'expected hardware-key wrap entry, got ${entry.type}',
      );
    }
    return crypto.secretboxOpen(entry.bytes, deviceKey);
  }

  /// Wraps [dek] to an X25519 [recipientPublicKey] via crypto_box_seal
  /// (spec §3, wrap type 0x03). The recipient later unwraps with their
  /// keypair. For a 32-byte DEK the output is 80 bytes.
  static WrapEntry wrapRecipient({
    required CryptoPort crypto,
    required Uint8List dek,
    required Uint8List recipientPublicKey,
  }) {
    final wrapped = crypto.boxSeal(dek, recipientPublicKey);
    return WrapEntry(type: WrapType.recipient, bytes: wrapped);
  }

  /// Unwraps a recipient WrapEntry to recover the DEK using the recipient's
  /// X25519 keypair. Throws [WrongPassphraseError] on authentication failure.
  static Uint8List unwrapRecipient({
    required CryptoPort crypto,
    required WrapEntry entry,
    required Uint8List recipientPublicKey,
    required Uint8List recipientSecretKey,
  }) {
    if (entry.type != WrapType.recipient) {
      throw CorruptedFileError(
        'expected recipient wrap entry, got ${entry.type}',
      );
    }
    return crypto.boxSealOpen(
      entry.bytes,
      recipientPublicKey,
      recipientSecretKey,
    );
  }
}
