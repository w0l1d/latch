// Proves the codec-version-strategies refactor (specs/003) is neutral for
// header encode/decode: header_corpus.json was produced by the UNTOUCHED
// pre-refactor code (see fixtures/generate_header_corpus.dart) via
// encodeHeader — a pure function, so post-refactor output must stay
// byte-identical. Never regenerate this fixture with the new code.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

Uint8List _bytes(int len, int seed) =>
    Uint8List.fromList(List.generate(len, (i) => (i + seed) % 256));

WrapEntry _wrap(WrapType type, int len, int seed) =>
    WrapEntry(type: type, bytes: _bytes(len, seed));

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final corpus =
      jsonDecode(File('test/fixtures/header_corpus.json').readAsStringSync())
          as Map<String, dynamic>;

  // Must reconstruct the exact same FileHeader shapes the generator built.
  final cases = <String, FileHeader>{
    'no_wraps': FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: _bytes(16, 0),
      opslimit: 2,
      memlimit: 65536,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.defaultChunkSize,
      keyIdHint: _bytes(16, 16),
      wraps: const [],
      secretstreamHeader: _bytes(24, 100),
    ),
    'one_passphrase_wrap': FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: _bytes(16, 1),
      opslimit: 3,
      memlimit: 131072,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.defaultChunkSize,
      keyIdHint: _bytes(16, 17),
      wraps: [_wrap(WrapType.passphrase, 48, 200)],
      secretstreamHeader: _bytes(24, 101),
    ),
    'multiple_wraps': FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: _bytes(16, 2),
      opslimit: 4,
      memlimit: 262144,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.defaultChunkSize,
      keyIdHint: _bytes(16, 18),
      wraps: [
        _wrap(WrapType.passphrase, 48, 210),
        _wrap(WrapType.hardwareKey, 48, 220),
        _wrap(WrapType.recipient, 80, 230),
      ],
      secretstreamHeader: _bytes(24, 102),
    ),
    'encrypted_filename_present': FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0x01,
      kdfId: FileHeader.kdfArgon2id,
      salt: _bytes(16, 3),
      opslimit: 2,
      memlimit: 65536,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.defaultChunkSize,
      keyIdHint: _bytes(16, 19),
      wraps: [_wrap(WrapType.passphrase, 48, 240)],
      secretstreamHeader: _bytes(24, 103),
      encryptedFilename: _bytes(37, 250),
    ),
    'min_chunk_size_boundary': FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: _bytes(16, 4),
      opslimit: FileHeader.minOpslimit,
      memlimit: FileHeader.minMemlimitKib,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.minChunkSize,
      keyIdHint: _bytes(16, 20),
      wraps: [_wrap(WrapType.passphrase, 48, 5)],
      secretstreamHeader: _bytes(24, 104),
    ),
    'max_chunk_size_boundary': FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: _bytes(16, 5),
      opslimit: FileHeader.maxOpslimit,
      memlimit: FileHeader.maxMemlimitKib,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.maxChunkSize,
      keyIdHint: _bytes(16, 21),
      wraps: [_wrap(WrapType.passphrase, 48, 6)],
      secretstreamHeader: _bytes(24, 105),
    ),
  };

  group('header corpus (pre-refactor fixtures)', () {
    for (final entry in cases.entries) {
      final name = entry.key;
      final header = entry.value;
      final pinned = corpus[name] as Map<String, dynamic>;

      test('$name encodes byte-identical to the pinned pre-refactor hex', () {
        final encoded = MyencCodec.encodeHeader(header);
        expect(_hex(encoded), pinned['encoded_hex']);
        expect(encoded.length, pinned['encoded_length']);
      });

      test('$name decodes the pinned bytes back to the same shape', () {
        final bytes = _fromHex(pinned['encoded_hex'] as String);
        final (decoded, consumed) = MyencCodec.decodeHeader(bytes);

        expect(consumed, bytes.length);
        expect(decoded.wraps.length, pinned['wrap_count']);
        expect(decoded.filenameEncrypted, pinned['filename_encrypted']);
        expect(decoded.chunkSize, pinned['chunk_size']);
        expect(decoded.version, header.version);
        expect(decoded.salt, header.salt);
        expect(decoded.keyIdHint, header.keyIdHint);
        expect(decoded.secretstreamHeader, header.secretstreamHeader);
        expect(decoded.encryptedFilename, header.encryptedFilename);
      });
    }
  });
}
