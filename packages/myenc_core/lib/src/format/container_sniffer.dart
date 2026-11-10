import 'dart:typed_data';
import 'file_header.dart';
import 'format_strategy.dart';
import 'format_version.dart';

enum SniffResult {
  /// Magic, known version and a plausible fixed header prefix.
  container,

  /// Not a `.latch` container, whatever its name says.
  notContainer,

  /// Starts like a container but carries a version this build does not know.
  newerVersion,

  /// Matches so far but too short to decide.
  truncated,
}

/// Header-prefix length the v1 sniffer needs: everything up to and including
/// the wrap count byte.
const int sniffPrefixLength = 56;

/// Identifies a `.latch` container from its first bytes. Pure, never throws,
/// never consults a file name.
SniffResult sniff(Uint8List b) {
  final magic = MyencCodecMagic.bytes;
  for (var i = 0; i < magic.length; i++) {
    if (i >= b.length) return SniffResult.truncated;
    if (b[i] != magic[i]) return SniffResult.notContainer;
  }
  if (b.length < 6) return SniffResult.truncated;
  if (!FormatVersionRegistry.all.containsKey(b[5])) {
    return SniffResult.newerVersion;
  }
  if (b.length < sniffPrefixLength) return SniffResult.truncated;

  final d = ByteData.sublistView(b);
  if (b[6] & ~FileHeader.knownFlagsMask != 0) return SniffResult.notContainer;
  if (b[7] != FileHeader.kdfArgon2id) return SniffResult.notContainer;
  if (d.getUint16(8, Endian.big) != 16) return SniffResult.notContainer;
  final ops = d.getUint32(26, Endian.big);
  final mem = d.getUint32(30, Endian.big);
  if (ops < FileHeader.minOpslimit || ops > FileHeader.maxOpslimit) {
    return SniffResult.notContainer;
  }
  if (mem < FileHeader.minMemlimitKib || mem > FileHeader.maxMemlimitKib) {
    return SniffResult.notContainer;
  }
  if (b[34] != FileHeader.cipherXchacha20Poly1305) {
    return SniffResult.notContainer;
  }
  final chunk = d.getUint32(35, Endian.big);
  if (chunk < FileHeader.minChunkSize || chunk > FileHeader.maxChunkSize) {
    return SniffResult.notContainer;
  }
  return SniffResult.container;
}
