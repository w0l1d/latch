import 'dart:typed_data';
import 'wrap_entry.dart';

class FileHeader {
  static const int supportedVersion = 1;
  static const int kdfArgon2id = 0x01;
  static const int cipherXchacha20Poly1305 = 0x01;
  static const int defaultChunkSize = 65536;

  // Decode-time bounds for untrusted header fields. These are format-level
  // sanity limits (DoS protection), not the security floor enforced at
  // encrypt time — a weak-but-well-formed file must still be decryptable.
  static const int minChunkSize = 64; // prevents pathological DoS (1-byte chunks)
  static const int maxChunkSize = 16 * 1024 * 1024; // 16 MiB
  static const int minOpslimit = 1; // libsodium argon2id13 minimum
  static const int maxOpslimit = 64;
  static const int minMemlimitKib = 8; // libsodium argon2id13 minimum (8 KiB)
  static const int maxMemlimitKib = 1024 * 1024; // 1 GiB

  // Flag bits defined in format v1; all others are reserved and must be zero.
  static const int knownFlagsMask = 0x01;

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
  /// Present only when [filenameEncrypted] is true (flags bit0 = 1).
  /// Encrypted with the DEK via secretbox.
  final Uint8List? encryptedFilename;

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
    this.encryptedFilename,
  });

  bool get filenameEncrypted => (flags & 0x01) != 0;
}
