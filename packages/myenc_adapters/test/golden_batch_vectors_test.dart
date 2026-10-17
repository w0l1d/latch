import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:myenc_adapters/src/crypto/sodium_crypto_adapter.dart';

/// Shared-salt (bulk "shared key") containers against an independent reference.
///
/// golden_batch_v1_{a,b}.latch are written by tool/gen_batch_vectors.py
/// (argon2-cffi + libsodium via ctypes — never the Dart code): two containers
/// with one salt and one KEK but different DEKs, wrap nonces and stream headers.
/// They live beside, and never replace, golden_v1.* — the frozen v1 evidence.
/// The Dart-produced direction is checked by `gen_batch_vectors.py verify`.
Future<Uint8List> _collect(Stream<Uint8List> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late SodiumCryptoAdapter adapter;
  late Map<String, dynamic> meta;
  late List<Uint8List> containers;

  setUpAll(() async {
    adapter = SodiumCryptoAdapter(await SodiumSumoInit.init());
    meta =
        jsonDecode(File('test/golden/golden_batch_v1.json').readAsStringSync())
            as Map<String, dynamic>;
    containers = [
      for (final f in (meta['files'] as List).cast<Map<String, dynamic>>())
        File('test/golden/${f['name']}').readAsBytesSync(),
    ];
  });

  Uint8List pass() => Uint8List.fromList(utf8.encode(meta['passphrase']));

  test(
    'independently-written shared-salt containers decrypt unchanged',
    () async {
      final files = (meta['files'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < files.length; i++) {
        final plain = await _collect(
          EnvelopeService(adapter).decrypt(
            ciphertext: Stream.value(containers[i]),
            passphrase: pass(),
          ),
        );
        expect(_hexOf(plain), files[i]['plaintext_hex']);
      }
    },
  );

  test('the fixture really shares the salt but nothing else', () {
    final (a, _) = MyencCodec.decodeHeader(containers[0]);
    final (b, _) = MyencCodec.decodeHeader(containers[1]);
    expect(_hexOf(a.salt), meta['shared_salt_hex']);
    expect(a.salt, b.salt);
    expect(a.secretstreamHeader, isNot(b.secretstreamHeader));
    expect(a.wraps.single.bytes, isNot(b.wraps.single.bytes));
    expect(a.keyIdHint, isNot(b.keyIdHint));
  });

  test('a reader re-derives the KEK from the header salt alone', () {
    final (a, _) = MyencCodec.decodeHeader(containers[0]);
    final kek = adapter.argon2idDerive(
      passphrase: pass(),
      salt: a.salt,
      opslimit: a.opslimit,
      memlimit: a.memlimit,
      outputLength: 32,
    );
    // The same KEK opens both containers' wraps.
    for (final c in containers) {
      final (h, _) = MyencCodec.decodeHeader(c);
      expect(adapter.secretboxOpen(h.wraps.single.bytes, kek), hasLength(32));
    }
  });

  test('wrong passphrase is rejected', () {
    expect(
      () => _collect(
        EnvelopeService(adapter).decrypt(
          ciphertext: Stream.value(containers[0]),
          passphrase: Uint8List.fromList(utf8.encode(meta['wrong_passphrase'])),
        ),
      ),
      throwsA(isA<WrongPassphraseError>()),
    );
  });

  test(
    'Dart BatchWrapKey output (real sodium) decrypts and shares its salt',
    () async {
      final svc = EnvelopeService(adapter);
      final key = await BatchWrapKey.derive(
        adapter,
        pass(),
        opslimit: 3,
        memlimit: 65536,
      );
      addTearDown(key.dispose);
      final seen = <String>{};
      for (final text in ['one', 'two, a little longer', '']) {
        final plain = Uint8List.fromList(utf8.encode(text));
        final sealed = await _collect(
          svc.encrypt(
            plaintext: Stream.value(plain),
            passphrase: pass(),
            params: const KdfParams(opslimit: 3, memlimit: 65536),
            batchKey: key,
          ),
        );
        final (h, _) = MyencCodec.decodeHeader(sealed);
        expect(h.salt, key.salt);
        seen.add(_hexOf(h.secretstreamHeader));
        expect(
          await _collect(
            svc.decrypt(ciphertext: Stream.value(sealed), passphrase: pass()),
          ),
          plain,
        );
      }
      expect(seen, hasLength(3));
    },
  );
}
