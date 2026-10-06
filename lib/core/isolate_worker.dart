import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:path/path.dart' as p;
import 'package:sodium/sodium_sumo.dart';
import 'bulk_plan.dart' show BulkKeyMode;
import 'crypto_erase.dart';
import 'verified_delete.dart';

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

/// A staged bulk run must not remove sources in the worker: the output is
/// still in the app cache and may yet fail to reach its folder. The main
/// isolate removes verified sources after relocation instead.
bool _deferDelete(Map<String, dynamic> task) =>
    task['outRelPaths'] != null && task['staged'] == true;

/// Destination for one output. Without [outRel] this is the historical
/// behaviour (`defaultPath` moved into [outputDir]). With [outRel] — bulk
/// mode — the file lands at `<outputDir>/<outRel>`, parent folders are created
/// on demand, and a name collision is resolved per output path.
String _resolveOut(
  FileIoDart io,
  String defaultPath,
  String? outputDir,
  String? outRel,
) {
  if (outRel == null || outputDir == null) {
    return io.resolveNameCollision(
      io.resolveOutputPath(defaultPath, outputDir),
    );
  }
  final target = p.joinAll([outputDir, ...outRel.split('/')]);
  Directory(p.dirname(target)).createSync(recursive: true);
  return io.resolveNameCollision(target);
}

List<String?> _outRels(Map<String, dynamic> task, int n) {
  final raw = task['outRelPaths'] as List?;
  return raw == null ? List<String?>.filled(n, null) : raw.cast<String?>();
}

/// Bulk runs only: once a write hits a full volume, the files not yet started
/// are reported as failed for lack of space (FR-026f) instead of each running
/// into the same wall. [e] is mapped for the file that actually failed.
String _spaceFailure(Map<String, dynamic> task) =>
    '${InsufficientSpaceError(shortfallBytes: 0, location: task['staged'] == true ? SpaceLocation.staging : SpaceLocation.destination)}';

void _failRemaining(
  Map<String, dynamic> task,
  SendPort mainPort,
  List<String> files,
  int from,
) {
  for (var j = from; j < files.length; j++) {
    mainPort.send({
      'type': 'file_done',
      'path': files[j],
      'ok': false,
      'error': _spaceFailure(task),
      'outPath': null,
      'verified': false,
      'sourceRemoved': false,
    });
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
  final outputDir = task['outputDir'] as String?;
  final keyIdHint = task['keyIdHint'] as Uint8List?;
  final deviceKey = task['deviceKey'] as Uint8List?;
  final verifyDelete = task['verifyDelete'] as bool? ?? false;
  final bulk = task['outRelPaths'] != null;
  final deleteOriginals =
      (task['deleteOriginals'] as bool) && !_deferDelete(task);
  final params = KdfParams(opslimit: opslimit, memlimit: memlimit);
  final outRels = _outRels(task, files.length);

  if (!params.meetsFloor()) {
    throw CorruptedFileError('KDF params below security floor');
  }

  final svc = EnvelopeService(crypto);

  // One Argon2id derivation for the whole run; every file still gets its own
  // DEK. Scoped to this call so the key never outlives the operation.
  final BatchWrapKey? batchKey =
      task['keyMode'] == BulkKeyMode.sharedPerBatch.name
      ? await BatchWrapKey.derive(
          crypto,
          passphrase,
          opslimit: opslimit,
          memlimit: memlimit,
        )
      : null;

  try {
    for (int i = 0; i < files.length; i++) {
      final path = files[i];

      try {
        final r = await _encryptOne(
          crypto,
          io,
          svc,
          path,
          passphrase,
          params,
          deleteOriginals,
          outputDir,
          keyIdHint,
          deviceKey,
          i,
          files.length,
          mainPort,
          outRels[i],
          verifyDelete,
          batchKey,
        );
        mainPort.send({
          'type': 'file_done',
          'path': path,
          'ok': true,
          'error': null,
          'outPath': r.outPath,
          'verified': r.verified,
          'sourceRemoved': r.sourceRemoved,
        });
      } catch (e) {
        final full = bulk && e is StorageFullError;
        mainPort.send({
          'type': 'file_done',
          'path': path,
          'ok': false,
          'error': full ? _spaceFailure(task) : '$e',
          'outPath': null,
          'verified': false,
          'sourceRemoved': false,
        });
        if (full) {
          _failRemaining(task, mainPort, files, i + 1);
          break;
        }
      }
    }
  } finally {
    batchKey?.dispose();
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

/// Returns the path the encrypted file was actually written to (may differ
/// from `<input>.latch` due to outputDir and collision renaming).
Future<({String outPath, bool verified, bool sourceRemoved})> _encryptOne(
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
  String? outRel,
  bool verifyDelete,
  BatchWrapKey? batchKey,
) async {
  final totalBytes = await io.fileSize(path);
  final before = verifyDelete ? File(path).statSync() : null;
  int readBytes = 0;

  Stream<Uint8List> tracked() async* {
    await for (final chunk in io.openRead(path)) {
      readBytes += chunk.length;
      yield chunk;
    }
  }

  final outPath = _resolveOut(io, '$path.latch', outputDir, outRel);
  // Announce the output before writing so the main isolate can remove the
  // in-flight <outPath>.tmp if the batch is cancelled mid-write.
  mainPort.send({'type': 'file_start', 'outPath': outPath});
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
      batchKey: batchKey,
    )) {
      sink.add(chunk);
      final fileFrac = totalBytes > 0
          ? (readBytes / totalBytes).clamp(0.0, 1.0)
          : 1.0;
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
    // Wait for that cleanup: reporting the failure while a partial-plaintext
    // temp is still on disk would let a caller observe it.
    try {
      await writeDone;
    } catch (_) {}
    rethrow;
  }
  // Close the sink only after the encrypt loop finishes cleanly, then wait
  // for the write to land on disk. writeDone errors (e.g. ENOSPC) are NOT
  // fed back into the now-closed sink — they propagate directly.
  await sink.close();
  await writeDone;

  if (!verifyDelete) {
    if (deleteOriginals) await io.deleteFile(path);
    return (outPath: outPath, verified: false, sourceRemoved: deleteOriginals);
  }

  // The container is only trusted once it reads back as exactly the source.
  // On any doubt it is the container that goes; the original is never touched.
  try {
    final after = File(path).statSync();
    if (after.size != before!.size || after.modified != before.modified) {
      throw VerificationFailedError('the file changed while it was encrypted');
    }
    await verifyContainerMatchesSource(
      svc: svc,
      io: io,
      containerPath: outPath,
      sourcePath: path,
      passphrase: passphrase,
      deviceKey: deviceKey,
    );
  } catch (e) {
    try {
      await io.deleteFile(outPath);
    } catch (_) {}
    if (e is VerificationFailedError) rethrow;
    throw VerificationFailedError('$e');
  }
  if (deleteOriginals) await io.deleteFile(path);
  return (outPath: outPath, verified: true, sourceRemoved: deleteOriginals);
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
      mainPort.send({'type': 'file_start', 'outPath': path});
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
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': true,
        'error': null,
        'outPath': path,
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
      mainPort.send({'type': 'file_start', 'outPath': path});
      await io.writeChunked(
        path,
        svc.addRecipient(
          ciphertext: io.openRead(path),
          passphrase: passphrase,
          recipientPublicKey: recipientPublicKey,
        ),
      );
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': true,
        'error': null,
        'outPath': path,
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
    mainPort.send({'type': 'progress', 'pct': (i + 1.0) / files.length});
  }
}

Future<void> _shredBatch(Map<String, dynamic> task, SendPort mainPort) async {
  final files = (task['files'] as List).cast<String>();

  for (int i = 0; i < files.length; i++) {
    final path = files[i];
    try {
      await CryptoErase.eraseAndDelete(path);
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': true,
        'error': null,
        'outPath': path,
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
  final outRels = _outRels(task, files.length);
  final bulk = task['outRelPaths'] != null;
  final verifyDelete = task['verifyDelete'] as bool? ?? false;
  final deleteContainers =
      (task['deleteOriginals'] as bool? ?? false) && !_deferDelete(task);
  final svc = EnvelopeService(crypto);

  for (int i = 0; i < files.length; i++) {
    final path = files[i];

    try {
      final r = await _decryptOne(
        crypto,
        io,
        svc,
        path,
        passphrase,
        outputDir,
        deviceKey,
        recipientPublicKey,
        recipientSecretKey,
        i,
        files.length,
        mainPort,
        outRels[i],
        verifyDelete,
        deleteContainers,
      );
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': true,
        'error': null,
        'outPath': r.outPath,
        if (verifyDelete) 'verified': r.verified,
        if (verifyDelete) 'sourceRemoved': r.sourceRemoved,
      });
    } catch (e) {
      final full = bulk && e is StorageFullError;
      mainPort.send({
        'type': 'file_done',
        'path': path,
        'ok': false,
        'error': full ? _spaceFailure(task) : '$e',
        'outPath': null,
        if (verifyDelete) 'verified': false,
        if (verifyDelete) 'sourceRemoved': false,
      });
      if (full) {
        _failRemaining(task, mainPort, files, i + 1);
        break;
      }
    }
  }

  mainPort.send({'type': 'progress', 'pct': 1.0});
}

/// Returns the path the plaintext was actually written to (may differ from
/// the input minus `.latch` due to outputDir and collision renaming).
Future<({String outPath, bool verified, bool sourceRemoved})> _decryptOne(
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
  String? outRel,
  bool verifyDelete,
  bool deleteContainer,
) async {
  final totalBytes = await io.fileSize(path);
  final before = verifyDelete ? File(path).statSync() : null;
  int readBytes = 0;

  Stream<Uint8List> tracked() async* {
    await for (final chunk in io.openRead(path)) {
      readBytes += chunk.length;
      yield chunk;
    }
  }

  final outPath = _resolveOut(
    io,
    io.withoutSuffix(path, '.latch'),
    outputDir,
    outRel,
  );
  // Announce the output before writing so the main isolate can remove the
  // in-flight <outPath>.tmp (partial plaintext!) if the batch is cancelled.
  mainPort.send({'type': 'file_start', 'outPath': outPath});
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
      final progress = totalBytes > 0
          ? (readBytes / totalBytes).clamp(0.0, 0.98)
          : 0.5;
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
    // Wait for that cleanup: reporting the failure while a partial-plaintext
    // temp is still on disk would let a caller observe it.
    try {
      await writeDone;
    } catch (_) {}
    rethrow;
  }
  // Close the sink only after the decrypt loop finishes cleanly, then wait
  // for the write to land on disk. writeDone errors are NOT fed back into
  // the now-closed sink — they propagate directly.
  await sink.close();
  await writeDone;

  if (!verifyDelete) {
    return (outPath: outPath, verified: false, sourceRemoved: false);
  }

  // The container is only removed once an independent second decrypt of it
  // matches the restored file. On any doubt the restored plaintext goes and
  // the container stays.
  try {
    final after = File(path).statSync();
    if (after.size != before!.size || after.modified != before.modified) {
      throw VerificationFailedError('the file changed while it was decrypted');
    }
    await verifyContainerMatchesSource(
      svc: svc,
      io: io,
      containerPath: path,
      sourcePath: outPath,
      passphrase: passphrase,
      deviceKey: deviceKey,
      recipientPublicKey: recipientPublicKey,
      recipientSecretKey: recipientSecretKey,
    );
  } catch (e) {
    try {
      await io.deleteFile(outPath);
    } catch (_) {}
    if (e is VerificationFailedError) rethrow;
    throw VerificationFailedError('$e');
  }
  if (deleteContainer) await io.deleteFile(path);
  return (outPath: outPath, verified: true, sourceRemoved: deleteContainer);
}
