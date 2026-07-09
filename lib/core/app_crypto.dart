import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypto_stub.dart' show PassphraseResult, CryptoStub;

// Set by AppCrypto.init() before any crypto calls.
late final SodiumSumo sodiumInstance;

class AppCrypto {
  static late final SodiumCryptoAdapter _crypto;
  static late final FileIoDart _io;
  static late final KdfParams _kdfParams;

  static Future<void> init(SodiumSumo sodium) async {
    sodiumInstance = sodium;
    _crypto = SodiumCryptoAdapter(sodium);
    _io = FileIoDart();
    _kdfParams = await _loadKdfParams();
  }

  static Future<KdfParams> _loadKdfParams() async {
    final prefs = await SharedPreferences.getInstance();
    final ops = prefs.getInt('kdf_opslimit') ?? KdfParams.defaults.opslimit;
    final mem = prefs.getInt('kdf_memlimit') ?? KdfParams.defaults.memlimit;
    return KdfParams(opslimit: ops, memlimit: mem);
  }

  // Pure heuristic — no real crypto.
  static PassphraseResult evaluate(String passphrase) =>
      CryptoStub.evaluate(passphrase);

  /// Encrypts each file in [files] (full paths).
  /// Yields overall progress 0.0–1.0; last value is 1.0.
  /// Throws [LatchError] subtypes on failure.
  static Stream<double> encryptFiles(
    List<String> files,
    String passphrase, {
    bool deleteOriginals = false,
  }) async* {
    final pw = Uint8List.fromList(passphrase.codeUnits);
    final svc = EnvelopeService(_crypto);

    for (int i = 0; i < files.length; i++) {
      final path = files[i];
      final totalBytes = await _io.fileSize(path);
      int readBytes = 0;

      Stream<Uint8List> tracked() async* {
        await for (final chunk in _io.openRead(path)) {
          readBytes += chunk.length;
          yield chunk;
        }
      }

      // Collect all encrypted chunks (bounded by file size + overhead).
      final cipherChunks = <Uint8List>[];
      int lastPct = -1;
      await for (final chunk in svc.encrypt(
        plaintext: tracked(),
        passphrase: pw,
        params: _kdfParams,
      )) {
        cipherChunks.add(chunk);
        final fileFrac =
            totalBytes > 0 ? (readBytes / totalBytes).clamp(0.0, 1.0) : 1.0;
        final overall = (i + fileFrac) / files.length;
        final pct = (overall * 100).round();
        if (pct != lastPct) {
          yield overall;
          lastPct = pct;
        }
      }

      final outPath = _io.resolveNameCollision('$path.latch');
      await _io.writeChunked(outPath, Stream.fromIterable(cipherChunks));

      if (deleteOriginals) await _io.deleteFile(path);

      yield (i + 1.0) / files.length;
    }

    yield 1.0;
  }

  /// Decrypts [filePath].
  /// Yields progress 0.0–1.0; last value is 1.0.
  /// Throws [WrongPassphraseError] or [CorruptedFileError] on failure.
  static Stream<double> decryptFile(String filePath, String passphrase) async* {
    final pw = Uint8List.fromList(passphrase.codeUnits);
    final svc = EnvelopeService(_crypto);

    final totalBytes = await _io.fileSize(filePath);
    int readBytes = 0;

    Stream<Uint8List> tracked() async* {
      await for (final chunk in _io.openRead(filePath)) {
        readBytes += chunk.length;
        yield chunk;
      }
    }

    final plainChunks = <Uint8List>[];
    int lastPct = -1;
    await for (final chunk in svc.decrypt(
      ciphertext: tracked(),
      passphrase: pw,
    )) {
      plainChunks.add(chunk);
      final progress =
          totalBytes > 0 ? (readBytes / totalBytes).clamp(0.0, 0.98) : 0.5;
      final pct = (progress * 100).round();
      if (pct != lastPct) {
        yield progress;
        lastPct = pct;
      }
    }

    final outPath = _io.resolveNameCollision(
        _io.withoutSuffix(filePath, '.latch'));
    await _io.writeChunked(outPath, Stream.fromIterable(plainChunks));

    yield 1.0;
  }
}
