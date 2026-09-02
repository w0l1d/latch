// Generator for the v1 compatibility corpus (specs/003).
//
//   cd packages/myenc_adapters && flutter test test/fixtures/compat_v1/generate_fixtures.dart
//
// It regenerates ONLY the manifest's "new_code" fixtures. The "pinned"
// fixtures were produced at commit 9fded2f — the code state BEFORE the
// FormatVersionStrategy extraction in 29531fb — and are the entire reason
// the corpus exists: compat_v1_test.dart proves the new code still reads
// those old bytes. Regenerating them with current code would replace the
// evidence with a tautology, so this generator refuses to write them and
// fails if one is missing (restore it from git rather than re-running).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:myenc_adapters/src/crypto/sodium_crypto_adapter.dart';

const _passphrase = 'compat-v1-fixture-passphrase';
const _wrongPassphrase = 'this-is-the-wrong-passphrase';
const _params = KdfParams(opslimit: 2, memlimit: 65536);

Future<List<int>> _collect(Stream<Uint8List> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return out;
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Deterministic pseudo-random bytes (not crypto-random — plaintext content
/// only, its entropy is irrelevant).
Uint8List _pattern(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) % 256));

Future<void> main() async {
  final sodium = await SodiumSumoInit.init();
  final adapter = SodiumCryptoAdapter(sodium);
  final envelope = EnvelopeService(adapter);
  final dir = Directory('test/fixtures/compat_v1');
  final rawDir = Directory('${dir.path}/raw')..createSync(recursive: true);
  final latchDir = Directory('${dir.path}/latch')..createSync(recursive: true);

  final cases = <String, Uint8List>{
    // Size classes
    'empty': Uint8List(0),
    'one_byte': Uint8List.fromList([0x42]),
    'small': utf8.encode('the quick brown fox jumps over the lazy dog'),
    // Content kinds — human text
    'ascii_text': utf8.encode(
      List.generate(8, (i) => 'line $i: the quick brown fox\n').join(),
    ),
    'unicode_text': utf8.encode(
      List.filled(
        4,
        'Ελληνικά · 日本語のテキスト · العربية · emoji 🚀🔐 · RTL עברית\n',
      ).join(),
    ),
    'json': utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'name': 'latch-compat',
        'values': List.generate(50, (i) => i * 3),
        'nested': {'ok': true, 'null': null, 'unicode': 'héllo wörld'},
      }),
    ),
    // Byte-pattern kinds
    'zero_bytes': Uint8List(1024),
    'all_bytes': Uint8List.fromList(
      List.generate(1024, (i) => i % 256),
    ), // every byte value 0x00–0xFF
    'binary': _pattern(4096, 7),
    // Chunk-boundary kinds (v1 default chunkSize = 65536)
    'boundary_64k': _pattern(65536, 11),
    'boundary_plus_1': _pattern(65537, 13),
    'multi_chunk': _pattern(70000, 17),
    // Large multi-chunk file
    'large_1mb': _pattern(1024 * 1024, 23),
  };

  final manifest =
      jsonDecode(File('${dir.path}/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final pinned = manifest['pinned'] as Map<String, dynamic>;
  final pinnedFiles = pinned['files'] as Map<String, dynamic>;

  // The passphrases are fixed by the pinned blobs — they cannot be changed
  // here without invalidating fixtures that cannot be regenerated.
  if (manifest['passphrase'] != _passphrase ||
      manifest['wrong_passphrase'] != _wrongPassphrase) {
    throw StateError(
      'manifest passphrases differ from this generator\'s constants; the '
      'pinned fixtures were encrypted with the manifest values.',
    );
  }

  // Guard, not a courtesy: the pinned blobs are old-code output and this
  // generator runs on new code. Verify they are present and unmodified, then
  // leave them alone.
  for (final name in pinnedFiles.keys) {
    final entry = pinnedFiles[name] as Map<String, dynamic>;
    final file = File('${dir.path}/${entry['latch_file']}');
    if (!file.existsSync()) {
      throw StateError(
        'pinned fixture ${entry['latch_file']} is missing — restore it from '
        'commit ${pinned['generated_at_commit']}; it cannot be regenerated.',
      );
    }
    final actual = _sha256Hex(file.readAsBytesSync());
    if (actual != entry['latch_sha256']) {
      throw StateError(
        'pinned fixture ${entry['latch_file']} does not match its recorded '
        'hash — restore it from commit ${pinned['generated_at_commit']} '
        'rather than updating the hash.',
      );
    }
  }

  final newFiles = <String, dynamic>{};
  for (final entry in cases.entries) {
    final name = entry.key;
    if (pinnedFiles.containsKey(name)) continue;

    final raw = entry.value;
    File('${rawDir.path}/$name.bin').writeAsBytesSync(raw);

    final latch = Uint8List.fromList(
      await _collect(
        envelope.encrypt(
          plaintext: Stream.value(raw),
          passphrase: utf8.encode(_passphrase),
          params: _params,
          filename: '$name.bin',
        ),
      ),
    );
    File('${latchDir.path}/$name.latch').writeAsBytesSync(latch);

    newFiles[name] = {
      'raw_sha256': _sha256Hex(raw),
      'raw_length': raw.length,
      'latch_file': 'latch/$name.latch',
      'raw_file': 'raw/$name.bin',
    };
  }

  (manifest['new_code'] as Map<String, dynamic>)['files'] = newFiles;

  File(
    '${dir.path}/manifest.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));

  // ignore: avoid_print
  print(
    'compat_v1: regenerated ${newFiles.length} new-code fixtures in '
    '${dir.path}; ${pinnedFiles.length} pinned fixtures verified and left '
    'untouched',
  );
}
