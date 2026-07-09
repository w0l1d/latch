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
  final passphrase = Uint8List.fromList('correct-passphrase'.codeUnits);
  final wrongPassphrase = Uint8List.fromList('wrong-passphrase'.codeUnits);

  setUp(() => svc = EnvelopeService(FakeCryptoPort()));

  group('EnvelopeService.encrypt / decrypt', () {
    test('round-trips small plaintext', () async {
      final plain = Uint8List.fromList('Hello, Latch!'.codeUnits);
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
          chunkSize: 32,
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
  });

  group('EnvelopeService error cases', () {
    late Uint8List validCiphertext;

    setUp(() async {
      final plain = Uint8List.fromList('secret data'.codeUnits);
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

    test('throws CorruptedFileError for invalid magic', () async {
      final corrupted = Uint8List.fromList(validCiphertext);
      corrupted[0] = 0xFF;
      expect(
        () => _collect(svc.decrypt(
          ciphertext: _stream([corrupted]),
          passphrase: passphrase,
        )),
        throwsA(isA<CorruptedFileError>()),
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
  });
}
