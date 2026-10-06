import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:myenc_core/myenc_core.dart';
import 'output_plan.dart';

/// Re-reads [containerPath], decrypts it (the FINAL tag is enforced by the
/// crypto adapter) and compares the plaintext with [sourcePath] in lockstep.
/// Throws [VerificationFailedError] on any difference in content or length, or
/// if the container will not decrypt at all. Nothing is buffered beyond a chunk.
Future<void> verifyContainerMatchesSource({
  required EnvelopeService svc,
  required FileIoDart io,
  required String containerPath,
  required String sourcePath,
  required Uint8List passphrase,
  Uint8List? deviceKey,
  Uint8List? recipientPublicKey,
  Uint8List? recipientSecretKey,
}) async {
  final src = StreamIterator<Uint8List>(io.openRead(sourcePath));
  var buf = Uint8List(0);
  var off = 0;
  try {
    await for (final chunk in svc.decrypt(
      ciphertext: io.openRead(containerPath),
      passphrase: passphrase,
      deviceKey: deviceKey,
      recipientPublicKey: recipientPublicKey,
      recipientSecretKey: recipientSecretKey,
    )) {
      var i = 0;
      while (i < chunk.length) {
        if (off >= buf.length) {
          if (!await src.moveNext()) {
            throw VerificationFailedError('the new copy is longer');
          }
          buf = src.current;
          off = 0;
          continue;
        }
        final n = math.min(chunk.length - i, buf.length - off);
        for (var k = 0; k < n; k++) {
          if (chunk[i + k] != buf[off + k]) {
            throw VerificationFailedError('the new copy differs');
          }
        }
        i += n;
        off += n;
      }
    }
    if (off < buf.length) {
      throw VerificationFailedError('the new copy is shorter');
    }
    while (await src.moveNext()) {
      if (src.current.isNotEmpty) {
        throw VerificationFailedError('the new copy is shorter');
      }
    }
  } on VerificationFailedError {
    rethrow;
  } catch (e) {
    throw VerificationFailedError('$e');
  } finally {
    await src.cancel();
  }
}

/// Removes inputs the worker verified but deliberately left alone because the
/// output was still staged. An input goes only when its output actually
/// reached a real destination; a failed or cache-only relocation keeps it.
/// Returns the paths that were removed.
Future<Set<String>> removeVerifiedSources({
  required Iterable<String> verifiedPaths,
  required Iterable<RelocatedOutput> relocated,
}) async {
  final landed = {
    for (final o in relocated)
      if (!o.failed && !o.keptInCache && o.sourcePath != null) o.sourcePath!,
  };
  final removed = <String>{};
  for (final path in verifiedPaths) {
    if (!landed.contains(path)) continue;
    try {
      await File(path).delete();
      removed.add(path);
    } on FileSystemException {
      // Could not remove (e.g. read-only grant): the input simply stays.
    }
  }
  return removed;
}
