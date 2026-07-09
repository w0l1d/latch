import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:sodium/sodium_sumo.dart';

// Messages are Map<String, dynamic> for safe cross-isolate serialization.
// Worker receives: {'cmd': 'encrypt'|'decrypt', ...}
// Main receives:  {'type': 'progress', 'pct': 0.5}
//                 {'type': 'done'}
//                 {'type': 'error', 'message': '...'}

/// Top-level entry point for Isolate.spawn.
/// Receives the main isolate's SendPort, initializes sodium,
/// processes a single task, and sends progress/done/error back.
void latchWorker(SendPort mainPort) async {
  final myPort = ReceivePort();
  mainPort.send(myPort.sendPort); // tell main how to reach us

  final raw = await myPort.first;
  myPort.close();
  final task = raw as Map<String, dynamic>;

  try {
    final sodium = await SodiumSumoInit.init();
    final crypto = SodiumCryptoAdapter(sodium);
    final io = FileIoDart();

    switch (task['cmd']) {
      case 'encrypt':
        await _encrypt(crypto, io, task, mainPort);
      case 'decrypt':
        await _decrypt(crypto, io, task, mainPort);
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

Future<void> _encrypt(
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
        final overall = (i + fileFrac) / files.length;
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

    mainPort.send({'type': 'progress', 'pct': (i + 1.0) / files.length});
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

Future<void> _decrypt(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final filePath = task['file'] as String;
  final passphrase = task['passphrase'] as Uint8List;
  final svc = EnvelopeService(crypto);

  final totalBytes = await io.fileSize(filePath);
  int readBytes = 0;

  Stream<Uint8List> tracked() async* {
    await for (final chunk in io.openRead(filePath)) {
      readBytes += chunk.length;
      yield chunk;
    }
  }

  final outPath =
      io.resolveNameCollision(io.withoutSuffix(filePath, '.latch'));
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
      final pct = (progress * 100).round();
      if (pct != lastPct) {
        mainPort.send({'type': 'progress', 'pct': progress});
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

  mainPort.send({'type': 'progress', 'pct': 1.0});
}
