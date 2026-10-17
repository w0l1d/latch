import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/staging_sweep.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('latch_sweep'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('removes stale staged sources and outputs, leaves the rest', () async {
    final src = Directory(p.join(tmp.path, stagedSourceDirName, 'Docs'))
      ..createSync(recursive: true);
    File(p.join(src.path, 'secret.txt')).writeAsStringSync('plaintext');
    final stage = Directory(p.join(tmp.path, stagedOutputDirName, 'a', 'b'))
      ..createSync(recursive: true);
    File(p.join(stage.path, 'out.txt')).writeAsStringSync('plaintext');
    final other = File(p.join(tmp.path, 'image_cache.bin'))
      ..writeAsBytesSync([1]);

    final removed = await StagingSweep.sweepOrphans(tempDir: tmp.path);

    expect(removed, 2);
    expect(
      Directory(p.join(tmp.path, stagedSourceDirName)).existsSync(),
      false,
    );
    expect(
      Directory(p.join(tmp.path, stagedOutputDirName)).existsSync(),
      false,
    );
    expect(other.existsSync(), isTrue);
  });

  test('nothing to sweep returns 0 and does not throw', () async {
    expect(await StagingSweep.sweepOrphans(tempDir: tmp.path), 0);
  });

  test('a missing cache directory does not throw', () async {
    final gone = p.join(tmp.path, 'nope');
    expect(await StagingSweep.sweepOrphans(tempDir: gone), 0);
  });
}
