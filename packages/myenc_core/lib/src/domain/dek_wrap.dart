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
}
