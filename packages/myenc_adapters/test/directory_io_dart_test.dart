import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:path/path.dart' as p;

Future<List<FolderEntry>> _walk(String root, {bool recursive = true}) =>
    DirectoryIoDart().walk(root, recursive: recursive).toList();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dirio_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void file(String rel, [String content = 'x']) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  test('empty directory yields nothing', () async {
    expect(await _walk(tmp.path), isEmpty);
  });

  test('nested tree: relative, slash-separated, never the root', () async {
    file('a.txt');
    file('d/b.txt', 'bb');
    file('d/e/c.txt', 'ccc');
    final r = await _walk(tmp.path);
    expect(r.map((e) => e.relativePath), [
      'a.txt',
      'd',
      'd/b.txt',
      'd/e',
      'd/e/c.txt',
    ]);
    expect(
      r.firstWhere((e) => e.relativePath == 'd/e/c.txt').stamp.sizeBytes,
      3,
    );
    expect(
      r.firstWhere((e) => e.relativePath == 'd').stamp.kind,
      EntryKind.directory,
    );
    expect(r.every((e) => !e.isSkipped), isTrue);
  });

  test('non-recursive lists the top level only', () async {
    file('a.txt');
    file('d/b.txt');
    final r = await _walk(tmp.path, recursive: false);
    expect(r.map((e) => e.relativePath), ['a.txt', 'd']);
  });

  test(
    'order is byte-wise on UTF-8 and independent of creation order',
    () async {
      for (final n in ['b', 'a.txt', 'a/z', 'é', 'Z', 'a b']) {
        file(n);
      }
      final r = (await _walk(tmp.path)).map((e) => e.relativePath).toList();
      final expected = [...r]
        ..sort((a, b) {
          final x = utf8.encode(a), y = utf8.encode(b);
          for (var i = 0; i < x.length && i < y.length; i++) {
            if (x[i] != y[i]) return x[i] - y[i];
          }
          return x.length - y.length;
        });
      expect(r, expected);
      expect(r, containsAll(['Z', 'b', 'é', 'a b', 'a.txt', 'a', 'a/z']));
      expect(
        r.indexOf('a.txt'),
        lessThan(r.indexOf('a/z')),
        reason: "'.' < '/'",
      );
    },
  );

  test('names with percent signs and unicode survive unmangled', () async {
    file('100%25.txt');
    file('naïve %41.txt');
    final r = (await _walk(tmp.path)).map((e) => e.relativePath);
    expect(r, containsAll(['100%25.txt', 'naïve %41.txt']));
  });

  test('symlinks are reported skipped and never followed', () async {
    file('real/inner.txt');
    Link(p.join(tmp.path, 'lnk')).createSync(p.join(tmp.path, 'real'));
    Link(
      p.join(tmp.path, 'flnk.txt'),
    ).createSync(p.join(tmp.path, 'real', 'inner.txt'));
    final r = await _walk(tmp.path);
    final paths = r.map((e) => e.relativePath).toList();
    expect(paths, isNot(contains('lnk/inner.txt')));
    for (final n in ['lnk', 'flnk.txt']) {
      final e = r.firstWhere((e) => e.relativePath == n);
      expect(e.isSkipped, isTrue);
      expect(e.stamp.kind, EntryKind.symlink);
    }
  });

  test('an ancestor-pointing link cannot cause a cycle', () async {
    file('d/f.txt');
    Link(p.join(tmp.path, 'd', 'up')).createSync(tmp.path);
    final r = await _walk(tmp.path).timeout(const Duration(seconds: 10));
    expect(r.length, 3);
    expect(r.firstWhere((e) => e.relativePath == 'd/up').isSkipped, isTrue);
  });

  test('a dangling link is listed, not dropped or fatal', () async {
    Link(p.join(tmp.path, 'dangling')).createSync(p.join(tmp.path, 'nope'));
    final r = await _walk(tmp.path);
    expect(r.single.relativePath, 'dangling');
    expect(r.single.isSkipped, isTrue);
  });

  test('an unreadable directory is skipped and listed', () async {
    file('ok.txt');
    file('locked/secret.txt');
    final locked = Directory(p.join(tmp.path, 'locked'));
    Process.runSync('chmod', ['000', locked.path]);
    addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
    if (Process.runSync('sh', [
          '-c',
          'ls "${locked.path}" 2>/dev/null',
        ]).exitCode ==
        0) {
      markTestSkipped('running as a user that ignores permissions');
      return;
    }
    final r = await _walk(tmp.path);
    final e = r.firstWhere((e) => e.relativePath == 'locked');
    expect(e.isSkipped, isTrue);
    expect(e.skipReason, contains('unreadable'));
    expect(r.map((e) => e.relativePath), contains('ok.txt'));
    expect(r.map((e) => e.relativePath), isNot(contains('locked/secret.txt')));
  });

  test('a FIFO is classified special, not fatal', () async {
    if (Platform.isWindows) return;
    final fifo = p.join(tmp.path, 'pipe');
    if (Process.runSync('mkfifo', [fifo]).exitCode != 0) {
      markTestSkipped('mkfifo unavailable');
      return;
    }
    file('a.txt');
    final r = await _walk(tmp.path);
    final e = r.firstWhere((e) => e.relativePath == 'pipe');
    expect(e.isSkipped, isTrue);
    expect(e.skipReason, 'special file');
  });

  test('every entry is yielded exactly once', () async {
    for (var i = 0; i < 50; i++) {
      file('d${i % 5}/f$i');
    }
    final r = (await _walk(tmp.path)).map((e) => e.relativePath).toList();
    expect(r.toSet().length, r.length);
    expect(r.length, 55);
  });

  test('stat: file, directory, missing, symlink; never follows', () async {
    file('f.txt', 'abcd');
    Directory(p.join(tmp.path, 'dir')).createSync();
    Link(p.join(tmp.path, 'l')).createSync(p.join(tmp.path, 'f.txt'));
    final io = DirectoryIoDart();
    final f = await io.stat(p.join(tmp.path, 'f.txt'));
    expect(f!.kind, EntryKind.file);
    expect(f.sizeBytes, 4);
    expect((await io.stat(p.join(tmp.path, 'dir')))!.kind, EntryKind.directory);
    expect(await io.stat(p.join(tmp.path, 'missing')), isNull);
    expect((await io.stat(p.join(tmp.path, 'l')))!.kind, EntryKind.symlink);
  });

  test('stat stamp changes when a file changes size', () async {
    file('f.txt', 'a');
    final io = DirectoryIoDart();
    final before = await io.stat(p.join(tmp.path, 'f.txt'));
    file('f.txt', 'abc');
    expect(await io.stat(p.join(tmp.path, 'f.txt')), isNot(before));
  });

  test('createDirectory honours recursive', () async {
    final io = DirectoryIoDart();
    final deep = p.join(tmp.path, 'x', 'y');
    await expectLater(
      io.createDirectory(deep),
      throwsA(isA<FileSystemException>()),
    );
    await io.createDirectory(deep, recursive: true);
    expect(Directory(deep).existsSync(), isTrue);
    await io.createDirectory(deep, recursive: true);
  });
}
