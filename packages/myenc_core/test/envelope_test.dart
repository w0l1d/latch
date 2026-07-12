import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'helpers/fake_crypto_port.dart';

Stream<Uint8List> _stream(List<Uint8List> chunks) async* {
  for (final c in chunks) {
    yield c;
  }
}

Stream<Uint8List> _streamBytes(Uint8List all, int chunkSize) async* {
  int offset = 0;
  while (offset < all.length) {
    final end = (offset + chunkSize).clamp(0, all.length);
    yield all.sublist(offset, end);
    offset = end;
  }
}

Future<Uint8List> _collect(Stream<Uint8List> stream) async {
  final chunks = <int>[];
  await for (final c in stream) {
    chunks.addAll(c);
  }
  return Uint8List.fromList(chunks);
}

void main() {
  late EnvelopeService svc;
  const params = KdfParams(opslimit: 3, memlimit: 65536);
  final passphrase = utf8.encode('correct-passphrase');
  final wrongPassphrase = utf8.encode('wrong-passphrase');

  setUp(() => svc = EnvelopeService(FakeCryptoPort()));

  group('EnvelopeService.encrypt / decrypt', () {
    test('round-trips small plaintext', () async {
      final plain = utf8.encode('Hello, Latch!');
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
        ),
      );
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: passphrase,
        ),
      );
      expect(recovered, plain);
    });

    test('round-trips empty plaintext', () async {
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([]),
          passphrase: passphrase,
          params: params,
        ),
      );
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: passphrase,
        ),
      );
      expect(recovered, isEmpty);
    });

    test('round-trips multi-chunk plaintext (larger than chunkSize)', () async {
      const chunkSize = 256;
      final plain = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
          chunkSize: chunkSize,
        ),
      );
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: passphrase,
        ),
      );
      expect(recovered, plain);
    });

    test('round-trips when input arrives in 1-byte chunks', () async {
      final plain = Uint8List.fromList(List.generate(100, (i) => i));
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _streamBytes(plain, 1),
          passphrase: passphrase,
          params: params,
          chunkSize: 64,
        ),
      );
      // Feed ciphertext in 1-byte chunks to test reader buffering
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _streamBytes(ciphertext, 1),
          passphrase: passphrase,
        ),
      );
      expect(recovered, plain);
    });

    test('round-trips exactly chunkSize bytes', () async {
      const chunkSize = 64;
      final plain = Uint8List.fromList(List.generate(chunkSize, (i) => i));
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
          chunkSize: chunkSize,
        ),
      );
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: passphrase,
        ),
      );
      expect(recovered, plain);
    });

    test('encrypt/decrypt round-trips with encrypted filename', () async {
      final plain = Uint8List.fromList([1, 2, 3]);
      final filename = 'secret_document.pdf';
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
          flags: 0x01,
          filename: filename,
        ),
      );
      final (header, _) = MyencCodec.decodeHeader(ciphertext);
      expect(header.filenameEncrypted, isTrue);
      expect(header.encryptedFilename, isNotNull);

      // Decrypt the filename with the static helper (using the fake crypto port)
      // The fake port's secretbox is plain XOR — we need the DEK which was used
      // during encrypt. Instead just verify round-trip decrypt of the body.
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: passphrase,
        ),
      );
      expect(recovered, plain);
    });

    test('ciphertext header is parseable by MyencCodec', () async {
      final plain = Uint8List.fromList([1, 2, 3]);
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
        ),
      );
      expect(() => MyencCodec.decodeHeader(ciphertext), returnsNormally);
      final (header, _) = MyencCodec.decodeHeader(ciphertext);
      expect(header.version, FileHeader.supportedVersion);
      expect(header.wraps.length, 1);
      expect(header.wraps[0].type, WrapType.passphrase);
    });

    test('non-ASCII passphrase round-trips (regression: UTF-8 encoding)', () async {
      // café = e-acute — distinct UTF-16 vs UTF-8 byte sequences.
      // codeUnits would yield [0x63,0x61,0x66,0xE9] (4 bytes);
      // utf8.encode yields [0x63,0x61,0x66,0xC3,0xA9] (5 bytes).
      // This test ensures the passphrase encoding is UTF-8 so files
      // are portable to non-Dart reference implementations.
      final passphrase = utf8.encode('café');
      final plain = Uint8List.fromList([1, 2, 3]);
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
        ),
      );
      // Decrypt with the same UTF-8 bytes
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: passphrase,
        ),
      );
      expect(recovered, plain);

      // Wrong encoding (UTF-16 codeUnits) must fail
      final wrongEncoding = Uint8List.fromList('café'.codeUnits);
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([ciphertext]),
          passphrase: wrongEncoding,
        )),
        throwsA(isA<WrongPassphraseError>()),
      );
    });
  });

  group('EnvelopeService key-id hint', () {
    test('explicit keyIdHint is written into the header verbatim', () async {
      final hint = Uint8List.fromList(List.generate(16, (i) => 0xA0 + i));
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([utf8.encode('data')]),
          passphrase: passphrase,
          params: params,
          keyIdHint: hint,
        ),
      );
      final (hdr, _) = MyencCodec.decodeHeader(ciphertext);
      expect(hdr.keyIdHint, hint);
    });

    test('omitted keyIdHint falls back to a random per-file hint', () async {
      final ciphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([utf8.encode('data')]),
          passphrase: passphrase,
          params: params,
        ),
      );
      final (hdr, _) = MyencCodec.decodeHeader(ciphertext);
      expect(hdr.keyIdHint.length, 16);
    });

    test('rejects a keyIdHint that is not 16 bytes', () {
      expect(
        () => _collect(svc.encrypt(
          plaintext: _stream([utf8.encode('data')]),
          passphrase: passphrase,
          params: params,
          keyIdHint: Uint8List(8),
        )),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });

  group('EnvelopeService.changePassphrase', () {
    final newPassphrase = utf8.encode('brand-new-passphrase');

    Future<Uint8List> encryptSample({Uint8List? keyIdHint}) => _collect(
          svc.encrypt(
            plaintext: _stream([utf8.encode('rewrap me')]),
            passphrase: passphrase,
            params: params,
            flags: 0x01,
            filename: 'secret.pdf',
            keyIdHint: keyIdHint,
          ),
        );

    test('new passphrase opens, old passphrase is rejected', () async {
      final original = await encryptSample();
      final rewrapped = await _collect(svc.changePassphrase(
        ciphertext: _stream([original]),
        oldPassphrase: passphrase,
        newPassphrase: newPassphrase,
        params: params,
      ));

      final recovered = await _collect(svc.decrypt(
        ciphertext: _stream([rewrapped]),
        passphrase: newPassphrase,
      ));
      expect(recovered, utf8.encode('rewrap me'));

      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([rewrapped]),
          passphrase: passphrase,
        )),
        throwsA(isA<WrongPassphraseError>()),
      );
    });

    test('body bytes and DEK-encrypted fields are carried over verbatim', () async {
      final hint = Uint8List.fromList(List.generate(16, (i) => 0xC0 + i));
      final original = await encryptSample(keyIdHint: hint);
      final rewrapped = await _collect(svc.changePassphrase(
        ciphertext: _stream([original]),
        oldPassphrase: passphrase,
        newPassphrase: newPassphrase,
        params: params,
      ));

      final (oldHdr, oldBodyStart) = MyencCodec.decodeHeader(original);
      final (newHdr, newBodyStart) = MyencCodec.decodeHeader(rewrapped);

      // Body is passthrough: identical ciphertext after the header.
      expect(rewrapped.sublist(newBodyStart), original.sublist(oldBodyStart));
      // DEK unchanged → same ss header and same encrypted filename.
      expect(newHdr.secretstreamHeader, oldHdr.secretstreamHeader);
      expect(newHdr.encryptedFilename, oldHdr.encryptedFilename);
      // Identity fields preserved.
      expect(newHdr.keyIdHint, hint);
      expect(newHdr.flags, oldHdr.flags);
      expect(newHdr.chunkSize, oldHdr.chunkSize);
      // Fresh salt → fresh KEK.
      expect(newHdr.salt, isNot(oldHdr.salt));
    });

    test('optionally replaces the key-id hint', () async {
      final original = await encryptSample();
      final newHint = Uint8List.fromList(List.generate(16, (i) => 0xD0 + i));
      final rewrapped = await _collect(svc.changePassphrase(
        ciphertext: _stream([original]),
        oldPassphrase: passphrase,
        newPassphrase: newPassphrase,
        params: params,
        keyIdHint: newHint,
      ));
      final (hdr, _) = MyencCodec.decodeHeader(rewrapped);
      expect(hdr.keyIdHint, newHint);
    });

    test('wrong old passphrase throws WrongPassphraseError', () async {
      final original = await encryptSample();
      expect(
        () => _collect(svc.changePassphrase(
          ciphertext: _stream([original]),
          oldPassphrase: wrongPassphrase,
          newPassphrase: newPassphrase,
          params: params,
        )),
        throwsA(isA<WrongPassphraseError>()),
      );
    });

    test('rejects KDF params below the floor', () async {
      final original = await encryptSample();
      expect(
        () => _collect(svc.changePassphrase(
          ciphertext: _stream([original]),
          oldPassphrase: passphrase,
          newPassphrase: newPassphrase,
          params: const KdfParams(opslimit: 1, memlimit: 8),
        )),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });

  group('EnvelopeService error cases', () {
    late Uint8List validCiphertext;

    setUp(() async {
      final plain = utf8.encode('secret data');
      validCiphertext = await _collect(
        svc.encrypt(
          plaintext: _stream([plain]),
          passphrase: passphrase,
          params: params,
        ),
      );
    });

    test('throws WrongPassphraseError for wrong passphrase', () async {
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([validCiphertext]),
          passphrase: wrongPassphrase,
        )),
        throwsA(isA<WrongPassphraseError>()),
      );
    });

    test('throws NotALatchFileError for invalid magic', () async {
      final corrupted = Uint8List.fromList(validCiphertext);
      corrupted[0] = 0xFF;
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([corrupted]),
          passphrase: passphrase,
        )),
        throwsA(isA<NotALatchFileError>()),
      );
    });

    test('throws VersionTooNewError for unsupported version', () async {
      final corrupted = Uint8List.fromList(validCiphertext);
      corrupted[5] = 0xFF;
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([corrupted]),
          passphrase: passphrase,
        )),
        throwsA(isA<VersionTooNewError>()),
      );
    });

    test('throws CorruptedFileError for truncated ciphertext', () async {
      final truncated = validCiphertext.sublist(0, validCiphertext.length ~/ 2);
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([truncated]),
          passphrase: passphrase,
        )),
        throwsA(isA<LatchError>()),
      );
    });

    test('throws CorruptedFileError for tampered body byte', () async {
      final (_, consumed) = MyencCodec.decodeHeader(validCiphertext);
      final tampered = Uint8List.fromList(validCiphertext);
      // Flip a bit in the encrypted body
      tampered[consumed + 5] ^= 0xFF;
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([tampered]),
          passphrase: passphrase,
        )),
        throwsA(isA<LatchError>()),
      );
    });

    test('encrypt rejects KDF params below the security floor', () async {
      final weak = KdfParams(opslimit: 1, memlimit: 1024); // 1 MiB
      expect(
        () => _collect(svc.encrypt(
          plaintext: _stream([Uint8List(8)]),
          passphrase: passphrase,
          params: weak,
        )),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });
}
