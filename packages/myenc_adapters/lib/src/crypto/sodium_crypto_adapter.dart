import 'dart:async';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';

class SodiumCryptoAdapter implements CryptoPort {
  final SodiumSumo _sodium;

  SodiumCryptoAdapter(this._sodium);

  @override
  Uint8List randomBytes(int length) => _sodium.randombytes.buf(length);

  @override
  Uint8List argon2idDerive({
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
    required int outputLength,
  }) {
    // pwhash expects Int8List password and memlimit in bytes (our KdfParams stores KiB).
    final pw = passphrase.buffer
        .asInt8List(passphrase.offsetInBytes, passphrase.lengthInBytes);
    final key = _sodium.crypto.pwhash.call(
      outLen: outputLength,
      password: pw,
      salt: salt,
      opsLimit: opslimit,
      memLimit: memlimit * 1024,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
    try {
      return Uint8List.fromList(key.extractBytes());
    } finally {
      key.dispose();
    }
  }

  // Output: nonce (nonceBytes) + MAC (macBytes) + ciphertext.
  @override
  Uint8List secretboxSeal(Uint8List plaintext, Uint8List key) {
    final nonce =
        _sodium.randombytes.buf(_sodium.crypto.secretBox.nonceBytes);
    final secureKey = SecureKey.fromList(_sodium, key);
    try {
      final encrypted = _sodium.crypto.secretBox.easy(
        message: plaintext,
        nonce: nonce,
        key: secureKey,
      );
      return Uint8List.fromList([...nonce, ...encrypted]);
    } finally {
      secureKey.dispose();
    }
  }

  @override
  Uint8List secretboxOpen(Uint8List ciphertext, Uint8List key) {
    final nonceLen = _sodium.crypto.secretBox.nonceBytes;
    final macLen = _sodium.crypto.secretBox.macBytes;
    if (ciphertext.length < nonceLen + macLen) throw WrongPassphraseError();

    final nonce = ciphertext.sublist(0, nonceLen);
    final cipher = ciphertext.sublist(nonceLen);
    final secureKey = SecureKey.fromList(_sodium, key);
    try {
      return _sodium.crypto.secretBox.openEasy(
        cipherText: cipher,
        nonce: nonce,
        key: secureKey,
      );
    } on SodiumException {
      throw WrongPassphraseError();
    } finally {
      secureKey.dispose();
    }
  }

  @override
  int get secretstreamHeaderBytes => _sodium.crypto.secretStream.headerBytes;

  // Dispose helper to clean up SecureKey on any stream termination.
  static void _disposeKey(SecureKey key, StreamController<Uint8List> ctrl) {
    key.dispose();
    if (!ctrl.isClosed) ctrl.close();
  }

  @override
  StreamTransformer<Uint8List, Uint8List> createEncryptTransformer(
      Uint8List key, int chunkSize) {
    // Copy the key into guarded memory NOW, before returning. The caller
    // (EnvelopeService) zeroizes its plaintext DEK immediately after this
    // returns; if the copy happened lazily inside fromBind() it would read
    // the already-zeroed array and encrypt the body under an all-zero key.
    final secureKey = SecureKey.fromList(_sodium, key);
    return StreamTransformer.fromBind((stream) {
      final controller = StreamController<Uint8List>(
        onCancel: () => secureKey.dispose(),
      );
      final xformer = _sodium.crypto.secretStream
          .createPushChunked(key: secureKey, chunkSize: chunkSize);
      // Reify as Stream<List<int>>: sodium's internal ChunkedStreamTransformer
      // is StreamTransformer<List<int>, _> and Dart's runtime variance check
      // rejects transform() on a stream reified as Stream<Uint8List>.
      xformer
          .bind(stream.map<List<int>>((c) => c))
          .map(Uint8List.fromList)
          .listen(
        controller.add,
        onError: controller.addError,
        onDone: () => _disposeKey(secureKey, controller),
        cancelOnError: true,
      );
      return controller.stream;
    });
  }

  @override
  StreamTransformer<Uint8List, Uint8List> createDecryptTransformer(
      Uint8List key, int chunkSize) {
    // Copy the key eagerly — see createEncryptTransformer. Decrypting with a
    // lazily-read (zeroed) key would fail authentication on the first chunk.
    final secureKey = SecureKey.fromList(_sodium, key);
    return StreamTransformer.fromBind((stream) {
      final controller = StreamController<Uint8List>(
        onCancel: () => secureKey.dispose(),
      );
      final xformer = _sodium.crypto.secretStream.createPullChunked(
        key: secureKey,
        chunkSize: chunkSize,
        requireFinalized: true,
      );
      xformer
          .bind(stream.map<List<int>>((c) => c))
          .map(Uint8List.fromList)
          .listen(
        controller.add,
        onError: (Object e, StackTrace st) {
          controller.addError(_mapDecryptError(e), st);
        },
        onDone: () => _disposeKey(secureKey, controller),
        cancelOnError: true,
      );
      return controller.stream;
    });
  }

  static Object _mapDecryptError(Object e) => switch (e) {
        StreamClosedEarlyException() =>
          CorruptedFileError('missing FINAL tag — file may be truncated'),
        InvalidHeaderException() =>
          CorruptedFileError('invalid secretstream header'),
        SodiumException() => CorruptedFileError('authentication failed'),
        _ => e,
      };
}
