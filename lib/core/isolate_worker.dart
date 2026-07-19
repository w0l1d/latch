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
      case 'add_recipient':
        await _addRecipientBatch(crypto, io, task, mainPort);
      case 'keygen':
        _keygen(sodium, mainPort);
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
  final deviceKey = task['deviceKey'] as Uint8List?;
  final params = KdfParams(opslimit: opslimit, memlimit: memlimit);

  if (!params.meetsFloor()) {
    throw CorruptedFileError('KDF params below security floor');
  }

  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      final outPath = await _encryptOne(crypto, io, svc, path, passphrase, params,
          deleteOriginals, outputDir, keyIdHint, deviceKey, i, files.length, mainPort);
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': true,
        'error': null,
        'outPath': outPath,
      });
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
        'outPath': null,
      });
    }
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

/// Returns the path the encrypted file was actually written to (may differ
/// from `<input>.latch` due to outputDir and collision renaming).
Future<String> _encryptOne(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  EnvelopeService svc,
  String path,
  Uint8List passphrase,
  KdfParams params,
  bool deleteOriginals,
  String? outputDir,
  Uint8List? keyIdHint,
  Uint8List? deviceKey,
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
      deviceKey: deviceKey,
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
  } catch (e) {
    // Sink is still open — forward the error so writeChunked can clean up
    // the temp file, then close and rethrow.
    sink.addError(e);
    await sink.close();
    rethrow;
  }
  // Close the sink only after the encrypt loop finishes cleanly, then wait
  // for the write to land on disk. writeDone errors (e.g. ENOSPC) are NOT
  // fed back into the now-closed sink — they propagate directly.
  await sink.close();
  await writeDone;

  if (deleteOriginals) await io.deleteFile(path);
  return outPath;
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
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null, 'outPath': path});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
        'outPath': null,
      });
    }
    mainPort.send({'type': 'progress', 'pct': (i + 1.0) / files.length});
  }
}

/// Generates an X25519 keypair for recipient sharing (spec §3, wrap 0x03).
/// The secret key is extracted to plain bytes for transfer to the main
/// isolate, which stores it in platform secure storage; the sodium-guarded
/// copy is disposed immediately.
void _keygen(SodiumSumo sodium, SendPort mainPort) {
  final kp = sodium.crypto.box.keyPair();
  try {
    mainPort.send({
      'type': 'keypair',
      'publicKey': Uint8List.fromList(kp.publicKey),
      'secretKey': kp.secretKey.extractBytes(),
    });
  } finally {
    kp.dispose();
  }
}

Future<void> _addRecipientBatch(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  Map<String, dynamic> task,
  SendPort mainPort,
) async {
  final files = (task['files'] as List).cast<String>();
  final passphrase = task['passphrase'] as Uint8List;
  final recipientPublicKey = task['recipientPublicKey'] as Uint8List;
  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];
    try {
      // writeChunked writes to <path>.tmp and renames — the original is
      // replaced atomically only after the full rewritten file is on disk.
      await io.writeChunked(
        path,
        svc.addRecipient(
          ciphertext: io.openRead(path),
          passphrase: passphrase,
          recipientPublicKey: recipientPublicKey,
        ),
      );
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null, 'outPath': path});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
        'outPath': null,
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
      mainPort.send({'type': 'file_done', 'path': path, 'ok': true, 'error': null, 'outPath': path});
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
        'outPath': null,
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
  final deviceKey = task['deviceKey'] as Uint8List?;
  final recipientPublicKey = task['recipientPublicKey'] as Uint8List?;
  final recipientSecretKey = task['recipientSecretKey'] as Uint8List?;
  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      final outPath = await _decryptOne(crypto, io, svc, path, passphrase, outputDir,
          deviceKey, recipientPublicKey, recipientSecretKey, i, files.length, mainPort);
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': true,
        'error': null,
        'outPath': outPath,
      });
    } catch (e) {
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': '$e',
        'outPath': null,
      });
    }
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

/// Returns the path the plaintext was actually written to (may differ from
/// the input minus `.latch` due to outputDir and collision renaming).
Future<String> _decryptOne(
  SodiumCryptoAdapter crypto,
  FileIoDart io,
  EnvelopeService svc,
  String path,
  Uint8List passphrase,
  String? outputDir,
  Uint8List? deviceKey,
  Uint8List? recipientPublicKey,
  Uint8List? recipientSecretKey,
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
      deviceKey: deviceKey,
      recipientPublicKey: recipientPublicKey,
      recipientSecretKey: recipientSecretKey,
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
  } catch (e) {
    // Sink is still open — forward the error so writeChunked can clean up
    // the temp file, then close and rethrow.
    sink.addError(e);
    await sink.close();
    rethrow;
  }
  // Close the sink only after the decrypt loop finishes cleanly, then wait
  // for the write to land on disk. writeDone errors are NOT fed back into
  // the now-closed sink — they propagate directly.
  await sink.close();
  await writeDone;
  return outPath;
}
