import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypto_stub.dart' show PassphraseResult, CryptoStub;
import 'isolate_worker.dart';
import 'passphrase_storage_service.dart';
import 'device_key_service.dart';
import 'recipient_key_service.dart';

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

  /// Device-bound key service — set by main() after the widget tree mounts.
  /// Used to add/check hardware-key wraps for device-bound recovery.
  static DeviceKeyService? deviceKeyService;

  /// Sharing keypair + recipient address book — set by main() after the
  /// widget tree mounts. Used for X25519 recipient wraps (spec §3, UC-6).
  static RecipientKeyService? recipientKeys;

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

  /// Spawns [latchWorker], sends [task], and translates the worker's message
  /// protocol into a progress stream (0.0–1.0). Per-file outcomes arrive via
  /// [onFileResult]; typed errors are rethrown on the main isolate.
  ///
  /// The worker's exit and uncaught-error ports are wired to the same
  /// ReceivePort, so a worker that dies without reporting (e.g. killed by the
  /// OS under memory pressure during Argon2id) surfaces as a stream error
  /// instead of hanging the caller forever.
  static Stream<double> _runBatch(
    Map<String, dynamic> task, {
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort,
        onExit: port.sendPort, onError: port.sendPort);
    bool done = false;

    try {
      SendPort? workerPort;
      await for (final msg in port) {
        if (msg == null) {
          // onExit fired before 'done' — the worker died without reporting.
          throw Exception('crypto isolate exited before finishing');
        }
        if (msg is List) {
          // onError port: [error, stackTrace] from an uncaught worker error.
          throw Exception('crypto isolate crashed: ${msg.firstOrNull}');
        }
        if (workerPort == null) {
          workerPort = msg as SendPort;
          workerPort.send(task);
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

  /// Encrypts each file in [files] (full paths).
  /// Yields overall progress 0.0–1.0; last value is 1.0.
  ///
  /// One file failing does not abort the rest (spec UC-3).
  /// If [onFileResult] is provided it is called per-file with the outcome.
  ///
  /// If [deviceKey] is provided (32-byte device-bound key), a hardware-key
  /// wrap is added so files can be opened on this device without the passphrase.
  ///
  /// Runs in a background isolate.
  static Stream<double> encryptFiles(
    List<String> files,
    String passphrase, {
    bool deleteOriginals = false,
    String? outputDir,
    String? keyIdHex,
    Uint8List? deviceKey,
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final pw = utf8.encode(passphrase);
    try {
      yield* _runBatch({
        'cmd': 'encrypt',
        'files': files,
        'passphrase': pw,
        'opslimit': _kdfParams.opslimit,
        'memlimit': _kdfParams.memlimit,
        'deleteOriginals': deleteOriginals,
        'outputDir': outputDir,
        'keyIdHint': _hexToBytes(keyIdHex),
        'deviceKey': deviceKey,
      }, onFileResult: onFileResult);
    } finally {
      pw.fillRange(0, pw.length, 0);
    }
  }

  /// Decrypts each file in [files] (full paths to .latch files).
  /// Yields overall progress 0.0–1.0; last value is 1.0.
  ///
  /// One file failing does not abort the rest (spec UC-3).
  /// If [onFileResult] is provided it is called per-file with the outcome.
  ///
  /// If [deviceKey] is provided, hardware-key wraps are tried as a fallback
  /// when the passphrase is wrong (device-bound recovery). If a recipient
  /// keypair is provided, recipient wraps are tried after that — files shared
  /// TO this install open even without the passphrase.
  ///
  /// Runs in a background isolate.
  static Stream<double> decryptFiles(
    List<String> files,
    String passphrase, {
    String? outputDir,
    Uint8List? deviceKey,
    Uint8List? recipientPublicKey,
    Uint8List? recipientSecretKey,
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final pw = utf8.encode(passphrase);
    try {
      yield* _runBatch({
        'cmd': 'decrypt',
        'files': files,
        'passphrase': pw,
        'outputDir': outputDir,
        'deviceKey': deviceKey,
        'recipientPublicKey': recipientPublicKey,
        'recipientSecretKey': recipientSecretKey,
      }, onFileResult: onFileResult);
    } finally {
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
    try {
      yield* _runBatch({
        'cmd': 'rewrap',
        'files': files,
        'oldPassphrase': oldPw,
        'newPassphrase': newPw,
        'opslimit': _kdfParams.opslimit,
        'memlimit': _kdfParams.memlimit,
        'keyIdHint': _hexToBytes(keyIdHex),
      }, onFileResult: onFileResult);
    } finally {
      oldPw.fillRange(0, oldPw.length, 0);
      newPw.fillRange(0, newPw.length, 0);
    }
  }

  /// Adds an X25519 recipient wrap to each .latch file in [files], replacing
  /// each file in place (atomic tmp+rename). The body is never re-encrypted —
  /// only a sealed-box wrap for [recipientPublicKey] is appended to the
  /// header's wrap list (spec §3, UC-6). The passphrase and any existing
  /// wraps keep working.
  ///
  /// Yields overall progress 0.0–1.0. One file failing does not abort the
  /// rest; per-file outcomes arrive via [onFileResult].
  static Stream<double> addRecipientFiles(
    List<String> files,
    String passphrase, {
    required Uint8List recipientPublicKey,
    void Function(String path, bool ok, String? error)? onFileResult,
  }) async* {
    if (files.isEmpty) return;
    final pw = utf8.encode(passphrase);
    try {
      yield* _runBatch({
        'cmd': 'add_recipient',
        'files': files,
        'passphrase': pw,
        'recipientPublicKey': recipientPublicKey,
      }, onFileResult: onFileResult);
    } finally {
      pw.fillRange(0, pw.length, 0);
    }
  }

  /// Generates a fresh X25519 sharing keypair in a worker isolate (sodium is
  /// only initialized there). Used as RecipientKeyService's generator.
  static Future<ShareKeypair> generateShareKeypair() async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort,
        onExit: port.sendPort, onError: port.sendPort);
    bool done = false;
    ShareKeypair? result;

    try {
      SendPort? workerPort;
      await for (final msg in port) {
        if (msg == null) {
          // onExit fired before 'done' — the worker died without reporting.
          throw StateError('keygen isolate exited before finishing');
        }
        if (msg is List) {
          // onError port: [error, stackTrace] from an uncaught worker error.
          throw Exception('keygen isolate crashed: ${msg.firstOrNull}');
        }
        if (workerPort == null) {
          workerPort = msg as SendPort;
          workerPort.send({'cmd': 'keygen'});
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'keypair':
            result = (
              publicKey: map['publicKey'] as Uint8List,
              secretKey: map['secretKey'] as Uint8List,
            );
          case 'error':
            _throwTypedError(map['code'] as String, map['message'] as String);
          case 'done':
            done = true;
            final kp = result;
            if (kp == null) {
              throw StateError('keygen worker finished without a keypair');
            }
            return kp;
        }
      }
      throw StateError('keygen worker exited unexpectedly');
    } finally {
      port.close();
      if (!done) isolate.kill(priority: Isolate.immediate);
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
    yield* _runBatch({'cmd': 'shred', 'files': files},
        onFileResult: onFileResult);
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
