import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypto_stub.dart' show PassphraseResult, CryptoStub;
import 'isolate_worker.dart';

class AppCrypto {
  static late final KdfParams _kdfParams;

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
  /// Throws [LatchError] subtypes on failure.
  ///
  /// Runs in a background isolate — Argon2id and streaming I/O
  /// never block the UI thread.
  static Stream<double> encryptFiles(
    List<String> files,
    String passphrase, {
    bool deleteOriginals = false,
  }) async* {
    final pw = utf8.encode(passphrase);
    final port = ReceivePort();
    final isolate = await Isolate.spawn(latchWorker, port.sendPort);
    bool done = false;

    try {
      // Handshake: get the worker's SendPort.
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
          });
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'progress':
            yield map['pct'] as double;
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

  /// Decrypts [filePath].
  /// Yields progress 0.0–1.0; last value is 1.0.
  /// Throws [WrongPassphraseError] or [CorruptedFileError] on failure.
  ///
  /// Runs in a background isolate — Argon2id never blocks the UI thread.
  static Stream<double> decryptFile(String filePath, String passphrase) async* {
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
            'file': filePath,
            'passphrase': pw,
          });
          continue;
        }
        final map = msg as Map<String, dynamic>;
        switch (map['type']) {
          case 'progress':
            yield map['pct'] as double;
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

  /// Reconstructs typed LatchError from the isolate's error report.
  static Never _throwTypedError(String code, String message) {
    switch (code) {
      case 'wrong_passphrase':
        throw WrongPassphraseError();
      case 'corrupted':
        throw CorruptedFileError(message);
      case 'version':
        throw VersionTooNewError(0);
      default:
        throw Exception('crypto isolate: $code — $message');
    }
  }
}
