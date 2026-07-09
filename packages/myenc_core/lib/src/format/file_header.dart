import 'dart:typed_data';
import 'wrap_entry.dart';

class FileHeader {
  static const int supportedVersion = 1;
  static const int kdfArgon2id = 0x01;
  static const int cipherXchacha20Poly1305 = 0x01;
  static const int defaultChunkSize = 65536;

  // XChaCha20-Poly1305 secretstream overhead per chunk (tag 1B + MAC 16B)
  static const int secretstreamOverhead = 17;
  // XChaCha20-Poly1305 secretstream header length
  static const int secretstreamHeaderLength = 24;

  final int version;
  final int flags;
  final int kdfId;
  final Uint8List salt;
  final int opslimit;
  final int memlimit;
  final int cipherId;
  final int chunkSize;
  final Uint8List keyIdHint;
  final List<WrapEntry> wraps;
  final Uint8List secretstreamHeader;

  const FileHeader({
    required this.version,
    required this.flags,
    required this.kdfId,
    required this.salt,
    required this.opslimit,
    required this.memlimit,
    required this.cipherId,
    required this.chunkSize,
    required this.keyIdHint,
    required this.wraps,
    required this.secretstreamHeader,
  });

  bool get filenameEncrypted => (flags & 0x01) != 0;
}
