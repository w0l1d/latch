// specs/003 US4: rewrap must not corrupt or drift the header layout.
// Parsing a header and re-encoding it through the same dispatch path the
// façade uses must reproduce the exact same bytes — proof that the strategy
// dispatch is a lossless round-trip, not just individually-correct halves.
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

void main() {
  test('parse then re-encode via the dispatch table is byte-identical', () {
    final h = FileHeader(
      version: FormatVersionRegistry.writeDefault.number,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: Uint8List.fromList(List.generate(16, (i) => i)),
      opslimit: 3,
      memlimit: 65536,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: FileHeader.defaultChunkSize,
      keyIdHint: Uint8List.fromList(List.generate(16, (i) => i + 16)),
      wraps: [
        WrapEntry(
          type: WrapType.passphrase,
          bytes: Uint8List.fromList(List.generate(48, (i) => i)),
        ),
      ],
      secretstreamHeader: Uint8List.fromList(List.generate(24, (i) => i + 100)),
    );

    final original = MyencCodec.encodeHeader(h);
    final (parsed, consumed) = MyencCodec.decodeHeader(original);
    expect(consumed, original.length);

    final strategy = formatVersionStrategies[parsed.version]!;
    final reEncoded = strategy.encode(parsed);

    expect(reEncoded, equals(original));
  });
}
