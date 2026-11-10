import 'dart:convert';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:test/test.dart';
import 'helpers/fake_crypto_port.dart';

Future<Uint8List> _container({bool filename = false}) async {
  final svc = EnvelopeService(FakeCryptoPort());
  final out = <int>[];
  await for (final c in svc.encrypt(
    plaintext: Stream.value(Uint8List.fromList(utf8.encode('hello'))),
    passphrase: Uint8List.fromList(utf8.encode('pw')),
    params: const KdfParams(opslimit: 3, memlimit: 65536),
    chunkSize: 64,
    flags: filename ? 1 : 0,
    filename: filename ? 'a.txt' : null,
  )) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

Uint8List _with(Uint8List src, int index, int value) =>
    Uint8List.fromList(src)..[index] = value;

void main() {
  late Uint8List good;
  setUpAll(() async => good = await _container());

  test(
    'a real container is recognised, with or without an encrypted name',
    () async {
      expect(sniff(good), SniffResult.container);
      expect(sniff(await _container(filename: true)), SniffResult.container);
    },
  );

  test('only the fixed prefix is needed', () {
    expect(sniff(good.sublist(0, sniffPrefixLength)), SniffResult.container);
  });

  test('every shorter prefix of a container is truncated, never a verdict', () {
    for (var n = 0; n < sniffPrefixLength; n++) {
      expect(sniff(good.sublist(0, n)), SniffResult.truncated, reason: '$n');
    }
  });

  test('empty input is truncated', () {
    expect(sniff(Uint8List(0)), SniffResult.truncated);
  });

  test('wrong magic at each of the five positions is notContainer', () {
    for (var i = 0; i < 5; i++) {
      expect(sniff(_with(good, i, good[i] ^ 0xFF)), SniffResult.notContainer);
    }
  });

  test('ordinary files are notContainer', () {
    expect(
      sniff(Uint8List.fromList(utf8.encode('hello world'))),
      SniffResult.notContainer,
    );
    expect(sniff(Uint8List(100)), SniffResult.notContainer);
    expect(
      sniff(Uint8List.fromList(List.filled(100, 0xFF))),
      SniffResult.notContainer,
    );
  });

  test('every version byte this build does not know is newerVersion', () {
    for (var v = 0; v <= 255; v++) {
      final r = sniff(_with(good, 5, v));
      if (FormatVersionRegistry.all.containsKey(v)) {
        expect(r, SniffResult.container);
      } else {
        expect(r, SniffResult.newerVersion, reason: 'version $v');
      }
    }
  });

  test('newer version is decided from six bytes, before length matters', () {
    expect(sniff(_with(good, 5, 9).sublist(0, 6)), SniffResult.newerVersion);
  });

  test('implausible fixed fields are notContainer', () {
    expect(
      sniff(_with(good, 6, 0x80)),
      SniffResult.notContainer,
      reason: 'flags',
    );
    expect(
      sniff(_with(good, 7, 0x02)),
      SniffResult.notContainer,
      reason: 'kdf',
    );
    expect(
      sniff(_with(good, 9, 15)),
      SniffResult.notContainer,
      reason: 'salt len',
    );
    expect(
      sniff(_with(good, 34, 0x02)),
      SniffResult.notContainer,
      reason: 'cipher',
    );
    expect(
      sniff(_with(good, 29, 0)),
      SniffResult.notContainer,
      reason: 'ops 0',
    );
    expect(
      sniff(_with(good, 26, 1)),
      SniffResult.notContainer,
      reason: 'ops huge',
    );
    expect(
      sniff(_with(good, 35, 0xFF)),
      SniffResult.notContainer,
      reason: 'chunk',
    );
  });

  test('agrees with the real decoder on the header it accepts', () {
    expect(() => MyencCodec.decodeHeader(good), returnsNormally);
    expect(sniff(good), SniffResult.container);
  });

  test('never throws on arbitrary prefixes', () {
    for (var seed = 0; seed < 500; seed++) {
      final b = Uint8List.fromList(
        List.generate(seed % 80, (i) => (seed * 31 + i * 17) & 0xFF),
      );
      expect(() => sniff(b), returnsNormally);
    }
  });
}
