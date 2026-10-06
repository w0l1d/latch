import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'helpers/fake_crypto_port.dart';

class _CountingCrypto extends FakeCryptoPort {
  int derivations = 0;

  @override
  Uint8List argon2idDerive({
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
    required int outputLength,
  }) {
    derivations++;
    return super.argon2idDerive(
      passphrase: passphrase,
      salt: salt,
      opslimit: opslimit,
      memlimit: memlimit,
      outputLength: outputLength,
    );
  }
}

Future<Uint8List> _collect(Stream<Uint8List> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

Stream<Uint8List> _one(Uint8List b) => Stream.value(b);

void main() {
  const params = KdfParams(opslimit: 3, memlimit: 65536);
  final passphrase = Uint8List.fromList(utf8.encode('batch-passphrase'));
  late _CountingCrypto crypto;
  late EnvelopeService svc;

  setUp(() {
    crypto = _CountingCrypto();
    svc = EnvelopeService(crypto);
  });

  Future<BatchWrapKey> key() => BatchWrapKey.derive(
    crypto,
    passphrase,
    opslimit: params.opslimit,
    memlimit: params.memlimit,
  );

  Future<Uint8List> seal(Uint8List plain, BatchWrapKey k) => _collect(
    svc.encrypt(
      plaintext: _one(plain),
      passphrase: passphrase,
      params: params,
      batchKey: k,
    ),
  );

  test(
    'shared-salt containers decrypt through the unchanged decrypt path',
    () async {
      final k = await key();
      final a = Uint8List.fromList(utf8.encode('first file'));
      final b = Uint8List.fromList(utf8.encode('second, longer file body'));
      final ca = await seal(a, k);
      final cb = await seal(b, k);

      expect(
        await _collect(
          svc.decrypt(ciphertext: _one(ca), passphrase: passphrase),
        ),
        a,
      );
      expect(
        await _collect(
          svc.decrypt(ciphertext: _one(cb), passphrase: passphrase),
        ),
        b,
      );
    },
  );

  test(
    'a wrong passphrase still fails fast on a shared-salt container',
    () async {
      final k = await key();
      final c = await seal(Uint8List.fromList([1, 2, 3]), k);
      expect(
        _collect(
          svc.decrypt(
            ciphertext: _one(c),
            passphrase: Uint8List.fromList(utf8.encode('wrong')),
          ),
        ),
        throwsA(isA<WrongPassphraseError>()),
      );
    },
  );

  test(
    'files share the salt but not DEK material, stream header or nonce',
    () async {
      final k = await key();
      final plain = Uint8List.fromList(utf8.encode('identical plaintext'));
      final c1 = await seal(plain, k);
      final c2 = await seal(plain, k);

      final (h1, _) = MyencCodec.decodeHeader(c1);
      final (h2, _) = MyencCodec.decodeHeader(c2);

      expect(h1.salt, k.salt);
      expect(h2.salt, h1.salt);
      expect(h1.secretstreamHeader, isNot(h2.secretstreamHeader));
      // Wrap bytes = nonce(24) + MAC + sealed DEK; distinct DEKs and nonces
      // both make the whole entry differ, and the nonce prefix must differ.
      final w1 = h1.wraps.single.bytes;
      final w2 = h2.wraps.single.bytes;
      expect(w1.sublist(0, 24), isNot(w2.sublist(0, 24)));
      expect(w1, isNot(w2));
      expect(h1.keyIdHint, isNot(h2.keyIdHint));
      expect(c1, isNot(c2));
    },
  );

  test('derives once per batch regardless of file count', () async {
    final k = await key();
    expect(crypto.derivations, 1);
    for (var i = 0; i < 5; i++) {
      await seal(Uint8List.fromList([i]), k);
    }
    expect(crypto.derivations, 1);
  });

  test('header params equal the key params', () async {
    final k = await key();
    final (h, _) = MyencCodec.decodeHeader(await seal(Uint8List(4), k));
    expect(h.opslimit, params.opslimit);
    expect(h.memlimit, params.memlimit);
  });

  test('mismatched params are rejected', () async {
    final k = await key();
    expect(
      _collect(
        svc.encrypt(
          plaintext: _one(Uint8List(4)),
          passphrase: passphrase,
          params: const KdfParams(opslimit: 4, memlimit: 65536),
          batchKey: k,
        ),
      ),
      throwsA(isA<CorruptedFileError>()),
    );
  });

  test('a disposed key throws StateError and emits nothing', () async {
    final k = await key();
    k.dispose();
    final chunks = <Uint8List>[];
    await expectLater(
      svc
          .encrypt(
            plaintext: _one(Uint8List(4)),
            passphrase: passphrase,
            params: params,
            batchKey: k,
          )
          .forEach(chunks.add),
      throwsA(isA<StateError>()),
    );
    expect(chunks, isEmpty);
  });

  test('dispose zeroes the KEK and is idempotent', () async {
    final k = await key();
    final kek = k.kek;
    expect(kek.any((b) => b != 0), isTrue);
    k.dispose();
    k.dispose();
    expect(kek.every((b) => b == 0), isTrue);
    expect(k.isDisposed, isTrue);
    expect(() => k.kek, throwsStateError);
  });

  test('derive rejects params below the security floor', () {
    expect(
      BatchWrapKey.derive(crypto, passphrase, opslimit: 1, memlimit: 65536),
      throwsA(isA<CorruptedFileError>()),
    );
  });

  test('the salt on the key is not mutated by encrypting', () async {
    final k = await key();
    final before = Uint8List.fromList(k.salt);
    await seal(Uint8List(8), k);
    expect(k.salt, before);
  });

  test('wrapPassphraseWithKek equals wrapPassphrase under the same KEK', () {
    final dek = Uint8List.fromList(List.generate(32, (i) => i));
    final salt = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final kek = crypto.argon2idDerive(
      passphrase: passphrase,
      salt: salt,
      opslimit: 3,
      memlimit: 65536,
      outputLength: 32,
    );
    final viaKek = DekWrap.wrapPassphraseWithKek(
      crypto: crypto,
      dek: dek,
      kek: kek,
    );
    expect(viaKek.type, WrapType.passphrase);
    final opened = DekWrap.unwrapPassphrase(
      crypto: crypto,
      entry: viaKek,
      passphrase: passphrase,
      salt: salt,
      opslimit: 3,
      memlimit: 65536,
    );
    expect(opened, dek);
  });
}
