import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:sodium/sodium_sumo.dart';

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
    }

    mainPort.send({'type': 'done'});
  } catch (e) {
    final code = switch (e) {
      WrongPassphraseError() => 'wrong_passphrase',
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
  final params = KdfParams(opslimit: opslimit, memlimit: memlimit);

  if (!params.meetsFloor()) {
    throw CorruptedFileError('KDF params below security floor');
  }

  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      await _encryptOne(crypto, io, svc, path, passphrase, params,
          deleteOriginals, i, files.length, mainPort);
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

  final outPath = io.resolveNameCollision('$path.latch');
  final sink = StreamController<Uint8List>();
  final writeDone = io.writeChunked(outPath, sink.stream);
  int lastPct = -1;

  try {
    await for (final chunk in svc.encrypt(
      plaintext: tracked(),
      passphrase: passphrase,
      params: params,
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

Future<void> _decryptBatch(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final files = (task['files'] as List).cast<String>();
  final passphrase = task['passphrase'] as Uint8List;
  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      await _decryptOne(crypto, io, svc, path, passphrase, i, files.length, mainPort);
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

  final outPath =
      io.resolveNameCollision(io.withoutSuffix(path, '.latch'));
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
