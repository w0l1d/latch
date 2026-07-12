import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'crypto_erase.dart';

/// Top-level entry point for Isolate.spawn.
void latchWorker(SendPort mainPort) async {
  final myPort = ReceivePort();
  mainPort.send(myPort.sendPort);

  final raw = await myPort.first;
  myPort.close();
  final task = raw as Map<String, dynamic>;

  try {
    final sodium = await SodiumSumoInit.init();
    final crypto = SodiumCryptoAdapter(sodium);
    final io = FileIoDart();

    switch (task['cmd']) {
      case 'encrypt':
        await _encryptBatch(crypto, io, task, mainPort);
      case 'decrypt':
        await _decryptBatch(crypto, io, task, mainPort);
      case 'rewrap':
        await _rewrapBatch(crypto, io, task, mainPort);
      case 'shred':
        await _shredBatch(task, mainPort);
    }

    mainPort.send({'type': 'done'});
  } catch (e) {
    final code = switch (e) {
      WrongPassphraseError() => 'wrong_passphrase',
      NotALatchFileError() => 'not_latch',
      CorruptedFileError() => 'corrupted',
      VersionTooNewError() => 'version',
      StorageFullError() => 'storage_full',
      _ => 'exception',
    };
    mainPort.send({'type': 'error', 'code': code, 'message': '$e'});
  }
}

Future<void> _encryptBatch(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final files = (task['files'] as List).cast<String>();
  final passphrase = task['passphrase'] as Uint8List;
  final opslimit = task['opslimit'] as int;
  final memlimit = task['memlimit'] as int;
  final deleteOriginals = task['deleteOriginals'] as bool;
  final outputDir = task['outputDir'] as String?;
  final keyIdHint = task['keyIdHint'] as Uint8List?;
  final params = KdfParams(opslimit: opslimit, memlimit: memlimit);

  if (!params.meetsFloor()) {
    throw CorruptedFileError('KDF params below security floor');
  }

  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      await _encryptOne(crypto, io, svc, path, passphrase, params,
          deleteOriginals, outputDir, keyIdHint, i, files.length, mainPort);
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
      });
    }
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

Future<void> _encryptOne(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  EnvelopeService svc,
  String path,
  Uint8List passphrase,
  KdfParams params,
  bool deleteOriginals,
  String? outputDir,
  Uint8List? keyIdHint,
  int index,
  int total,
  SendPort mainPort,
) async {
  final totalBytes = await io.fileSize(path);
  int readBytes = 0;

  Stream<Uint8List> tracked() async* {
    await for (final chunk in io.openRead(path)) {
      readBytes += chunk.length;
      yield chunk;
    }
  }

  final outPath = io.resolveNameCollision(
      io.resolveOutputPath('$path.latch', outputDir));
  final sink = StreamController<Uint8List>();
  final writeDone = io.writeChunked(outPath, sink.stream);
  int lastPct = -1;

  try {
    await for (final chunk in svc.encrypt(
      plaintext: tracked(),
      passphrase: passphrase,
      params: params,
      keyIdHint: keyIdHint,
    )) {
      sink.add(chunk);
      final fileFrac =
          totalBytes > 0 ? (readBytes / totalBytes).clamp(0.0, 1.0) : 1.0;
      final overall = (index + fileFrac) / total;
      final pct = (overall * 100).round();
      if (pct != lastPct) {
        mainPort.send({'type': 'progress', 'pct': overall});
        lastPct = pct;
      }
    }
    await sink.close();
    await writeDone;
  } catch (e) {
    sink.addError(e);
    await sink.close();
    rethrow;
  }

  if (deleteOriginals) await io.deleteFile(path);

  mainPort.send({'type': 'progress', 'pct': (index + 1.0) / total});
}

Future<void> _rewrapBatch(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final files = (task['files'] as List).cast<String>();
  final oldPassphrase = task['oldPassphrase'] as Uint8List;
  final newPassphrase = task['newPassphrase'] as Uint8List;
  final opslimit = task['opslimit'] as int;
  final memlimit = task['memlimit'] as int;
  final keyIdHint = task['keyIdHint'] as Uint8List?;
  final params = KdfParams(opslimit: opslimit, memlimit: memlimit);
  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];
    try {
      // writeChunked writes to <path>.tmp and renames — the original is
      // replaced atomically only after the full rewrapped file is on disk.
      await io.writeChunked(
        path,
        svc.changePassphrase(
          ciphertext: io.openRead(path),
          oldPassphrase: oldPassphrase,
          newPassphrase: newPassphrase,
          params: params,
          keyIdHint: keyIdHint,
        ),
      );
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
      });
    }
    mainPort.send({'type': 'progress', 'pct': (i + 1.0) / files.length});
  }
}

Future<void> _shredBatch(
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final files = (task['files'] as List).cast<String>();

  for (int i = 0; i < files.length; i++) {
    final path = files[i];
    try {
      await CryptoErase.eraseAndDelete(path);
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
      });
    }
    mainPort.send({'type': 'progress', 'pct': (i + 1.0) / files.length});
  }
}

Future<void> _decryptBatch(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final files = (task['files'] as List).cast<String>();
  final passphrase = task['passphrase'] as Uint8List;
  final outputDir = task['outputDir'] as String?;
  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      await _decryptOne(
          crypto, io, svc, path, passphrase, outputDir, i, files.length, mainPort);
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
      });
    }
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

Future<void> _decryptOne(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  EnvelopeService svc,
  String path,
  Uint8List passphrase,
  String? outputDir,
  int index,
  int total,
  SendPort mainPort,
) async {
  final totalBytes = await io.fileSize(path);
  int readBytes = 0;

  Stream<Uint8List> tracked() async* {
    await for (final chunk in io.openRead(path)) {
      readBytes += chunk.length;
      yield chunk;
    }
  }

  final outPath = io.resolveNameCollision(
      io.resolveOutputPath(io.withoutSuffix(path, '.latch'), outputDir));
  final sink = StreamController<Uint8List>();
  final writeDone = io.writeChunked(outPath, sink.stream);
  int lastPct = -1;

  try {
    await for (final chunk in svc.decrypt(
      ciphertext: tracked(),
      passphrase: passphrase,
    )) {
      sink.add(chunk);
      final progress =
          totalBytes > 0 ? (readBytes / totalBytes).clamp(0.0, 0.98) : 0.5;
      final overall = (index + progress) / total;
      final pct = (overall * 100).round();
      if (pct != lastPct) {
        mainPort.send({'type': 'progress', 'pct': overall});
        lastPct = pct;
      }
    }
    await sink.close();
    await writeDone;
  } catch (e) {
    sink.addError(e);
    await sink.close();
    rethrow;
  }

  mainPort.send({'type': 'progress', 'pct': (index + 1.0) / total});
}
