import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypto_stub.dart' show PassphraseResult, CryptoStub;
import 'isolate_worker.dart';
import 'passphrase_storage_service.dart';

/// Per-file outcome from a batch encrypt or decrypt operation.
class BatchResult {
  final String path;
  final bool ok;
  final String? errorMessage;
  const BatchResult({required this.path, required this.ok, this.errorMessage});
}

class AppCrypto {
  static late final KdfParams _kdfParams;

  /// Lazy-initialized singleton — set by main() after the widget tree mounts
  /// so platform channels are available.
  static PassphraseStorageService? passphraseStorage;

  static Future<void> init() async {
    _kdfParams = await _loadKdfParams();
  }

  static Future<KdfParams> _loadKdfParams() async {
    final prefs = await SharedPreferences.getInstance();
    final ops = prefs.getInt('kdf_opslimit') ?? KdfParams.defaults.opslimit;
    final mem = prefs.getInt('kdf_memlimit') ?? KdfParams.defaults.memlimit;
    final params = KdfParams(opslimit: ops, memlimit: mem);
    if (!params.meetsFloor()) return KdfParams.defaults;
    return params;
  }

  // Pure heuristic — no real crypto.
  static PassphraseResult evaluate(String passphrase) =>
      CryptoStub.evaluate(passphrase);

  /// Encrypts each file in [files] (full paths).
  /// Yields overall progress 0.0–1.0; last value is 1.0.
  ///
  /// One file failing does not abort the rest (spec UC-3).
  /// If [onFileResult] is provided it is called per-file with the outcome.
  ///
  /// Runs in a background isolate.
  static Stream<double> encryptFiles(
    List<String> files,
    String passphrase, {
    bool deleteOriginals = false,
    String? outputDir,
    String? keyIdHex,
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final pw = utf8.encode(passphrase);
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort);
    bool done = false;

    try {
      SendPort? workerPort;
      await for (final msg in port) {
        if (workerPort == null) {
          workerPort = msg as SendPort;
          workerPort.send({
            'cmd': 'encrypt',
            'files': files,
            'passphrase': pw,
            'opslimit': _kdfParams.opslimit,
            'memlimit': _kdfParams.memlimit,
            'deleteOriginals': deleteOriginals,
            'outputDir': outputDir,
            'keyIdHint': _hexToBytes(keyIdHex),
          });
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'progress':
            yield map['pct'] as double;
          case 'file_done':
            onFileResult?.call(
              map['path'] as String,
              map['ok'] as bool,
              map['error'] as String?,
            );
          case 'error':
            _throwTypedError(map['code'] as String, map['message'] as String);
          case 'done':
            done = true;
            return;
        }
      }
    } finally {
      port.close();
      if (!done) isolate.kill(priority: Isolate.immediate);
      pw.fillRange(0, pw.length, 0);
    }
  }

  /// Decrypts each file in [files] (full paths to .latch files).
  /// Yields overall progress 0.0–1.0; last value is 1.0.
  ///
  /// One file failing does not abort the rest (spec UC-3).
  /// If [onFileResult] is provided it is called per-file with the outcome.
  ///
  /// Runs in a background isolate.
  static Stream<double> decryptFiles(
    List<String> files,
    String passphrase, {
    String? outputDir,
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final pw = utf8.encode(passphrase);
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort);
    bool done = false;

    try {
      SendPort? workerPort;
      await for (final msg in port) {
        if (workerPort == null) {
          workerPort = msg as SendPort;
          workerPort.send({
            'cmd': 'decrypt',
            'files': files,
            'passphrase': pw,
            'outputDir': outputDir,
          });
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'progress':
            yield map['pct'] as double;
          case 'file_done':
            onFileResult?.call(
              map['path'] as String,
              map['ok'] as bool,
              map['error'] as String?,
            );
          case 'error':
            _throwTypedError(map['code'] as String, map['message'] as String);
          case 'done':
            done = true;
            return;
        }
      }
    } finally {
      port.close();
      if (!done) isolate.kill(priority: Isolate.immediate);
      pw.fillRange(0, pw.length, 0);
    }
  }

  /// Re-wraps each .latch file in [files] under a new passphrase, replacing
  /// each file in place (atomic tmp+rename). The body is never re-encrypted —
  /// only the DEK wrap and KDF salt in the header change (spec UC: change
  /// passphrase = re-wrap DEK only).
  ///
  /// Yields overall progress 0.0–1.0. One file failing does not abort the
  /// rest; per-file outcomes arrive via [onFileResult].
  static Stream<double> changePassphraseFiles(
    List<String> files,
    String oldPassphrase,
    String newPassphrase, {
    String? keyIdHex,
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final oldPw = utf8.encode(oldPassphrase);
    final newPw = utf8.encode(newPassphrase);
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort);
    bool done = false;

    try {
      SendPort? workerPort;
      await for (final msg in port) {
        if (workerPort == null) {
          workerPort = msg as SendPort;
          workerPort.send({
            'cmd': 'rewrap',
            'files': files,
            'oldPassphrase': oldPw,
            'newPassphrase': newPw,
            'opslimit': _kdfParams.opslimit,
            'memlimit': _kdfParams.memlimit,
            'keyIdHint': _hexToBytes(keyIdHex),
          });
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'progress':
            yield map['pct'] as double;
          case 'file_done':
            onFileResult?.call(
              map['path'] as String,
              map['ok'] as bool,
              map['error'] as String?,
            );
          case 'error':
            _throwTypedError(map['code'] as String, map['message'] as String);
          case 'done':
            done = true;
            return;
        }
      }
    } finally {
      port.close();
      if (!done) isolate.kill(priority: Isolate.immediate);
      oldPw.fillRange(0, oldPw.length, 0);
      newPw.fillRange(0, newPw.length, 0);
    }
  }

  /// Crypto-erase each file in [files] (full paths to .latch files).
  /// Overwrites the header with random bytes (destroying the DEK), then
  /// deletes the file. The body becomes permanent noise (spec UC-10).
  ///
  /// Yields overall progress 0.0–1.0. One file failing does not abort the
  /// rest; per-file outcomes arrive via [onFileResult].
  static Stream<double> secureDeleteFiles(
    List<String> files, {
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort);
    bool done = false;

    try {
      SendPort? workerPort;
      await for (final msg in port) {
        if (workerPort == null) {
          workerPort = msg as SendPort;
          workerPort.send({'cmd': 'shred', 'files': files});
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'progress':
            yield map['pct'] as double;
          case 'file_done':
            onFileResult?.call(
              map['path'] as String,
              map['ok'] as bool,
              map['error'] as String?,
            );
          case 'error':
            _throwTypedError(map['code'] as String, map['message'] as String);
          case 'done':
            done = true;
            return;
        }
      }
    } finally {
      port.close();
      if (!done) isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Convenience: single-file decrypt with the batch API.
  /// Throws on failure (unlike [decryptFiles] which reports via callback).
  static Stream<double> decryptFile(String filePath, String passphrase) async* {
    String? error;
    yield* decryptFiles([filePath], passphrase, onFileResult: (path, ok, err) {
      error = err;
    });
    if (error != null) {
      if (error!.contains('WrongPassphraseError')) throw WrongPassphraseError();
      if (error!.contains('NotALatchFileError')) throw NotALatchFileError();
      if (error!.contains('CorruptedFileError')) throw CorruptedFileError(error!);
      if (error!.contains('VersionTooNewError')) throw VersionTooNewError(0);
      throw Exception(error);
    }
  }

  /// Decodes a hex key-id into bytes; null/malformed hex yields null so the
  /// isolate falls back to a random per-file hint.
  static Uint8List? _hexToBytes(String? hex) {
    if (hex == null || hex.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  /// Reconstructs typed LatchError from the isolate's error report.
  static Never _throwTypedError(String code, String message) {
    switch (code) {
      case 'wrong_passphrase':
        throw WrongPassphraseError();
      case 'not_latch':
        throw NotALatchFileError();
      case 'corrupted':
        throw CorruptedFileError(message);
      case 'version':
        throw VersionTooNewError(0);
      case 'storage_full':
        throw StorageFullError();
      default:
        throw Exception('crypto isolate: $code — $message');
    }
  }
}
