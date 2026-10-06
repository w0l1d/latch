import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_adapters/myenc_adapters.dart';

void main() {
  const sample =
      'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
      '/dev/disk3s5 971350180 400000000 123456 77% /System/Volumes/Data\n';

  test('parses POSIX df -Pk output to bytes', () {
    expect(FreeSpaceDart.parseDfAvailableBytes(sample), 123456 * 1024);
  });

  test('parse returns null for garbage', () {
    for (final s in [
      '',
      'only one line',
      'h\nshort row',
      'h\na b c notanumber d',
    ]) {
      expect(FreeSpaceDart.parseDfAvailableBytes(s), isNull, reason: s);
    }
  });

  test('wraps a long device name onto the data line (-P keeps one line)', () {
    expect(
      FreeSpaceDart.parseDfAvailableBytes('h\n/dev/x 10 2 8 20% /m\n'),
      8 * 1024,
    );
  });

  test('null when unsupported, without invoking df', () async {
    var called = false;
    final fs = FreeSpaceDart(
      supported: false,
      df: (_) async {
        called = true;
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(await fs.freeBytesAt('/x'), isNull);
    expect(called, isFalse);
  });

  test(
    'null on non-zero exit, thrown error, and timeout-free garbage',
    () async {
      expect(
        await FreeSpaceDart(
          supported: true,
          df: (_) async => ProcessResult(0, 1, '', 'e'),
        ).freeBytesAt('/nope'),
        isNull,
      );
      expect(
        await FreeSpaceDart(
          supported: true,
          df: (_) async => throw const ProcessException('df', []),
        ).freeBytesAt('/x'),
        isNull,
      );
      expect(
        await FreeSpaceDart(
          supported: true,
          df: (_) async => ProcessResult(0, 0, 'junk', ''),
        ).freeBytesAt('/x'),
        isNull,
      );
    },
  );

  test('real df answers positively for the temp dir on desktop', () async {
    if (!(Platform.isMacOS || Platform.isLinux)) return;
    final v = await FreeSpaceDart().freeBytesAt(Directory.systemTemp.path);
    expect(v, isNotNull);
    expect(v, greaterThan(0));
  });

  test('real df for a nonexistent path returns null, never throws', () async {
    if (!(Platform.isMacOS || Platform.isLinux)) return;
    expect(await FreeSpaceDart().freeBytesAt('/definitely/not/a/path'), isNull);
  });
}
