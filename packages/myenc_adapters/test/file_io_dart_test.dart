import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmpDir;
  late FileIoDart io;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('latch_io_test');
    io = FileIoDart();
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  String path(String name) => p.join(tmpDir.path, name);

  group('resolveNameCollision', () {
    test('returns the path unchanged when no collision', () {
      final target = path('report.pdf');
      expect(io.resolveNameCollision(target), target);
    });

    test('suffixes with _2 when the file already exists', () async {
      final target = path('report.pdf');
      await File(target).writeAsString('x');
      final resolved = io.resolveNameCollision(target);
      expect(resolved, path('report_2.pdf'));
    });

    test('increments the suffix past existing numbered files', () async {
      await File(path('report.pdf')).writeAsString('x');
      await File(path('report_2.pdf')).writeAsString('x');
      await File(path('report_3.pdf')).writeAsString('x');
      final resolved = io.resolveNameCollision(path('report.pdf'));
      expect(resolved, path('report_4.pdf'));
    });

    test('handles files with no extension', () async {
      await File(path('README')).writeAsString('x');
      final resolved = io.resolveNameCollision(path('README'));
      expect(resolved, path('README_2'));
    });
  });

  group('writeChunked', () {
    test('writes chunks and renames atomically (no .tmp left)', () async {
      final target = path('out.bin');
      final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
      await io.writeChunked(target, Stream.value(data));
      expect(await File(target).exists(), isTrue);
      expect(await File('$target.tmp').exists(), isFalse);
      expect(await File(target).readAsBytes(), data);
    });

    test('leaves no output and no .tmp when the stream errors', () async {
      final target = path('out.bin');
      Stream<Uint8List> erroring() async* {
        yield Uint8List.fromList([1, 2, 3]);
        throw StateError('boom');
      }

      await expectLater(
        io.writeChunked(target, erroring()),
        throwsA(isA<StateError>()),
      );
      expect(await File(target).exists(), isFalse);
      expect(await File('$target.tmp').exists(), isFalse);
    });
  });

  group('suffix helpers', () {
    test('withSuffix / withoutSuffix round-trip', () {
      expect(io.withSuffix('a/b.pdf', '.latch'), 'a/b.pdf.latch');
      expect(io.withoutSuffix('a/b.pdf.latch', '.latch'), 'a/b.pdf');
      expect(io.withoutSuffix('a/b.pdf', '.latch'), 'a/b.pdf');
    });
  });
}
