import 'dart:async';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';

// Deterministic fake crypto for unit tests. NOT secure — correctness only.
class FakeCryptoPort implements CryptoPort {
  int _seq = 0;

  @override
  Uint8List randomBytes(int length) {
    final result = Uint8List(length);
    for (int i = 0; i < length; i++) {
      result[i] = (_seq * 37 + i * 13 + 7) & 0xFF;
      _seq++;
    }
    return result;
  }

  @override
  Uint8List argon2idDerive({
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
    required int outputLength,
  }) {
    final out = Uint8List(outputLength);
    for (int i = 0; i < outputLength; i++) {
      out[i] = passphrase[i % passphrase.length] ^
          salt[i % salt.length] ^
          (i & 0xFF);
    }
    return out;
  }

  // Output: nonce(24) + mac(16) + ciphertext
  @override
  Uint8List secretboxSeal(Uint8List plaintext, Uint8List key) {
    final nonce = randomBytes(24);
    final cipher = Uint8List(plaintext.length);
    int xorAcc = 0;
    for (int i = 0; i < plaintext.length; i++) {
      cipher[i] = plaintext[i] ^ key[i % key.length];
      xorAcc ^= plaintext[i];
    }
    final mac = Uint8List(16)..fillRange(0, 16, xorAcc);
    return Uint8List.fromList([...nonce, ...mac, ...cipher]);
  }

  @override
  Uint8List secretboxOpen(Uint8List ciphertext, Uint8List key) {
    if (ciphertext.length < 40) throw WrongPassphraseError();
    final macBytes = ciphertext.sublist(24, 40);
    final cipher = ciphertext.sublist(40);
    final plain = Uint8List(cipher.length);
    int xorAcc = 0;
    for (int i = 0; i < cipher.length; i++) {
      plain[i] = cipher[i] ^ key[i % key.length];
      xorAcc ^= plain[i];
    }
    for (final b in macBytes) {
      if (b != xorAcc) throw WrongPassphraseError();
    }
    return plain;
  }

  @override
  int get secretstreamHeaderBytes => FileHeader.secretstreamHeaderLength;

  @override
  StreamTransformer<Uint8List, Uint8List> createEncryptTransformer(
      Uint8List key, int chunkSize) {
    // Capture header deterministically at creation time (before binding).
    final header = randomBytes(secretstreamHeaderBytes);
    return _FakeEncryptTransformer(key, chunkSize, header);
  }

  @override
  StreamTransformer<Uint8List, Uint8List> createDecryptTransformer(
      Uint8List key, int chunkSize) {
    return _FakeDecryptTransformer(key, chunkSize);
  }
}

// Chunk format: tag(1) + mac(16) + plaintext(n). Overhead = 17 bytes.
// Encrypt emits header(24B) first; buffering is to [chunkSize]-byte plaintext blocks.
final class _FakeEncryptTransformer
    extends StreamTransformerBase<Uint8List, Uint8List> {
  final Uint8List _key;
  final int _chunkSize;
  final Uint8List _header;

  _FakeEncryptTransformer(this._key, this._chunkSize, this._header);

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) async* {
    yield _header;

    final buf = <int>[];
    int idx = 0;

    await for (final chunk in stream) {
      buf.addAll(chunk);
      while (buf.length >= _chunkSize) {
        final plain = Uint8List.fromList(buf.sublist(0, _chunkSize));
        buf.removeRange(0, _chunkSize);
        yield _encryptChunk(plain, false, idx++, _key);
      }
    }
    yield _encryptChunk(Uint8List.fromList(buf), true, idx, _key);
  }

  static Uint8List _encryptChunk(
      Uint8List plain, bool isFinal, int idx, Uint8List key) {
    final cipher = Uint8List(plain.length);
    int xorAcc = 0;
    for (int i = 0; i < plain.length; i++) {
      cipher[i] = plain[i] ^ key[i % key.length] ^ (idx & 0xFF);
      xorAcc ^= plain[i];
    }
    final tag = isFinal ? 0x02 : 0x00;
    final mac = Uint8List(16)..fillRange(0, 16, xorAcc);
    return Uint8List.fromList([tag, ...mac, ...cipher]);
  }
}

// Decrypt transformer: skips header(24B), then decrypts tag(1)+mac(16)+data per chunk.
// Chunk index is tracked across the async* generator so XOR inversion is correct.
final class _FakeDecryptTransformer
    extends StreamTransformerBase<Uint8List, Uint8List> {
  final Uint8List _key;
  final int _chunkSize;

  _FakeDecryptTransformer(this._key, this._chunkSize);

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) => _run(stream);

  Stream<Uint8List> _run(Stream<Uint8List> stream) async* {
    final buf = <int>[];
    bool headerConsumed = false;
    bool gotFinal = false;
    int idx = 0;
    final encChunkSize = _chunkSize + FileHeader.secretstreamOverhead;

    await for (final incoming in stream) {
      buf.addAll(incoming);

      if (!headerConsumed) {
        if (buf.length < FileHeader.secretstreamHeaderLength) continue;
        buf.removeRange(0, FileHeader.secretstreamHeaderLength);
        headerConsumed = true;
      }

      while (buf.length >= encChunkSize) {
        final raw = Uint8List.fromList(buf.sublist(0, encChunkSize));
        buf.removeRange(0, encChunkSize);
        final (:plain, :isFinal) = _decryptChunk(raw, idx++, _key);
        yield plain;
        if (isFinal) { gotFinal = true; break; }
      }
      if (gotFinal) break;
    }

    if (!gotFinal) {
      if (!headerConsumed) throw CorruptedFileError('truncated: header missing');
      if (buf.isEmpty) throw CorruptedFileError('empty ciphertext body');
      final (:plain, :isFinal) =
          _decryptChunk(Uint8List.fromList(buf), idx, _key);
      if (!isFinal) {
        throw CorruptedFileError('missing FINAL tag — file may be truncated');
      }
      if (plain.isNotEmpty) yield plain;
    }
  }

  static ({Uint8List plain, bool isFinal}) _decryptChunk(
      Uint8List cipher, int idx, Uint8List key) {
    if (cipher.length < 17) {
      throw CorruptedFileError('chunk too short (${cipher.length} bytes)');
    }
    final tag = cipher[0];
    final macBytes = cipher.sublist(1, 17);
    final ct = cipher.sublist(17);
    final plain = Uint8List(ct.length);
    int xorAcc = 0;
    for (int i = 0; i < ct.length; i++) {
      plain[i] = ct[i] ^ key[i % key.length] ^ (idx & 0xFF);
      xorAcc ^= plain[i];
    }
    for (final b in macBytes) {
      if (b != xorAcc) throw CorruptedFileError('authentication failed');
    }
    return (plain: plain, isFinal: tag == 0x02);
  }
}
