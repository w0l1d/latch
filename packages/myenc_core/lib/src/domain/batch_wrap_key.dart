import 'dart:typed_data';
import '../format/myenc_errors.dart';
import '../ports/crypto_port.dart';
import 'dek_wrap.dart';
import 'kdf_params.dart';

/// A passphrase-derived key-encryption key (KEK) shared by every container in
/// one bulk run, so Argon2id is paid once per batch instead of once per file.
///
/// Containers written with it are ordinary v1 containers: the header carries
/// [salt], and a reader re-derives the same KEK from passphrase + salt exactly
/// as for a single file. Each file still gets its own random DEK, secretstream
/// header and wrap nonce. The trade-off is that files in one batch share a
/// salt, so a single guess of the passphrase tests all of them at once.
final class BatchWrapKey {
  final Uint8List salt;
  final int opslimit;
  final int memlimit;
  final Uint8List _kek;
  bool _disposed = false;

  BatchWrapKey._(this.salt, this.opslimit, this.memlimit, this._kek);

  static Future<BatchWrapKey> derive(
    CryptoPort crypto,
    Uint8List passphrase, {
    required int opslimit,
    required int memlimit,
  }) async {
    if (!KdfParams(opslimit: opslimit, memlimit: memlimit).meetsFloor()) {
      throw CorruptedFileError('KDF params below security floor');
    }
    final salt = crypto.randomBytes(16);
    final kek = crypto.argon2idDerive(
      passphrase: passphrase,
      salt: salt,
      opslimit: opslimit,
      memlimit: memlimit,
      outputLength: DekWrap.kekLength,
    );
    return BatchWrapKey._(salt, opslimit, memlimit, kek);
  }

  bool get isDisposed => _disposed;

  /// The derived KEK. Callers must not retain or mutate it. Throws
  /// [StateError] once the key has been disposed.
  Uint8List get kek {
    if (_disposed) throw StateError('BatchWrapKey used after dispose');
    return _kek;
  }

  /// Zeroes the KEK. Idempotent.
  void dispose() {
    if (_disposed) return;
    _kek.fillRange(0, _kek.length, 0);
    _disposed = true;
  }
}
