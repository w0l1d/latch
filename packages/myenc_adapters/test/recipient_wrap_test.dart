import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:myenc_adapters/src/crypto/sodium_crypto_adapter.dart';

/// End-to-end recipient wrap test with real libsodium.
///
/// Generates an X25519 keypair via libsodium, encrypts a small payload,
/// adds a recipient wrap, then decrypts with the recipient keypair.
/// Also verifies that a wrong secret key is rejected.

Future<List<int>> _collect(Stream<Uint8List> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return out;
}

Stream<Uint8List> _stream(Uint8List data) async* {
  yield data;
}

/// Generates an X25519 keypair and hands back plain byte copies, disposing
/// the SecureKey. KeyPair.publicKey is already a Uint8List; only the secret
/// key lives in guarded memory.
({Uint8List pk, Uint8List sk}) _keypairBytes(SodiumSumo sodium) {
  final kp = sodium.crypto.box.keyPair();
  try {
    return (
      pk: Uint8List.fromList(kp.publicKey),
      sk: kp.secretKey.extractBytes(),
    );
  } finally {
    kp.dispose();
  }
}

void main() {
  late SodiumSumo sodium;
  late SodiumCryptoAdapter adapter;
  late EnvelopeService svc;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });
  setUp(() {
    adapter = SodiumCryptoAdapter(sodium);
    svc = EnvelopeService(adapter);
  });

  group('Recipient wrap with real libsodium', () {
    test('addRecipient + decrypt with recipient keypair round-trips', () async {
      final (pk: recipientPk, sk: recipientSk) = _keypairBytes(sodium);

      final passphrase = utf8.encode('test passphrase');
      final plain = utf8.encode('Hello from real sodium recipient wrap!');
      const params = KdfParams(opslimit: 2, memlimit: 65536);

      // Encrypt with passphrase only.
      final original = Uint8List.fromList(
        await _collect(
          svc.encrypt(
            plaintext: _stream(Uint8List.fromList(plain)),
            passphrase: passphrase,
            params: params,
          ),
        ),
      );

      // Add a recipient wrap.
      final updated = Uint8List.fromList(
        await _collect(
          svc.addRecipient(
            ciphertext: _stream(original),
            passphrase: passphrase,
            recipientPublicKey: recipientPk,
          ),
        ),
      );

      // Verify header has a recipient wrap of 80 bytes.
      final (hdr, _) = MyencCodec.decodeHeader(updated);
      final recipientWraps = hdr.wraps.where(
        (w) => w.type == WrapType.recipient,
      );
      expect(recipientWraps, isNotEmpty);
      expect(recipientWraps.first.bytes.length, 80);

      // Decrypt with the recipient keypair.
      final recovered = await _collect(
        svc.decrypt(
          ciphertext: _stream(updated),
          passphrase: utf8.encode('wrong'),
          recipientPublicKey: recipientPk,
          recipientSecretKey: recipientSk,
        ),
      );
      expect(recovered, plain);
    });

    test('wrong recipient secret key is rejected', () async {
      // Two X25519 keypairs — one for sealing, one for the wrong open.
      final (pk: sealPk, sk: _) = _keypairBytes(sodium);
      final (pk: _, sk: wrongSk) = _keypairBytes(sodium);

      final passphrase = utf8.encode('test passphrase');
      final plain = utf8.encode('wrong key test');
      const params = KdfParams(opslimit: 2, memlimit: 65536);

      final original = Uint8List.fromList(
        await _collect(
          svc.encrypt(
            plaintext: _stream(Uint8List.fromList(plain)),
            passphrase: passphrase,
            params: params,
          ),
        ),
      );

      final updated = Uint8List.fromList(
        await _collect(
          svc.addRecipient(
            ciphertext: _stream(original),
            passphrase: passphrase,
            recipientPublicKey: sealPk,
          ),
        ),
      );

      // Wrong secret key must fail.
      expect(
        () => _collect(
          svc.decrypt(
            ciphertext: _stream(updated),
            passphrase: utf8.encode('wrong'),
            recipientPublicKey: sealPk,
            recipientSecretKey: wrongSk,
          ),
        ),
        throwsA(isA<WrongPassphraseError>()),
      );
    });

    test('body bytes are verbatim after addRecipient', () async {
      final (pk: recipientPk, sk: recipientSk) = _keypairBytes(sodium);

      final passphrase = utf8.encode('body passthrough test');
      final plain = utf8.encode('body must not change');
      const params = KdfParams(opslimit: 2, memlimit: 65536);

      final original = Uint8List.fromList(
        await _collect(
          svc.encrypt(
            plaintext: _stream(Uint8List.fromList(plain)),
            passphrase: passphrase,
            params: params,
          ),
        ),
      );

      final updated = Uint8List.fromList(
        await _collect(
          svc.addRecipient(
            ciphertext: _stream(original),
            passphrase: passphrase,
            recipientPublicKey: recipientPk,
          ),
        ),
      );

      // Body bytes past the header must be identical.
      final (_, oldBodyStart) = MyencCodec.decodeHeader(original);
      final (_, newBodyStart) = MyencCodec.decodeHeader(updated);
      expect(updated.sublist(newBodyStart), original.sublist(oldBodyStart));

      // Also verify the original passphrase still works.
      final recovered = await _collect(
        svc.decrypt(ciphertext: _stream(updated), passphrase: passphrase),
      );
      expect(recovered, plain);

      // And the recipient keypair works.
      final recovered2 = await _collect(
        svc.decrypt(
          ciphertext: _stream(updated),
          passphrase: utf8.encode('wrong'),
          recipientPublicKey: recipientPk,
          recipientSecretKey: recipientSk,
        ),
      );
      expect(recovered2, plain);
    });
  });
}
