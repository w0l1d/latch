import 'dart:typed_data';
import 'file_header.dart';
import 'wrap_entry.dart';
import 'myenc_errors.dart';

class MyencCodec {
  static const _magic = [0x4C, 0x41, 0x54, 0x43, 0x48]; // LATCH
  static const _saltLength = 16;
  static const _keyIdLength = 16;

  // Encodes the full file header (magic through secretstream header).
  static Uint8List encodeHeader(FileHeader h) {
    int wrapBytes = 0;
    for (final w in h.wraps) {
      wrapBytes += 3 + w.bytes.length; // type(1) + len(2) + data
    }
    int filenameBytes = 0;
    if (h.filenameEncrypted && h.encryptedFilename != null) {
      filenameBytes = 2 + h.encryptedFilename!.length; // len(2) + data
    }
    final totalSize =
        56 + wrapBytes + filenameBytes + FileHeader.secretstreamHeaderLength;
    final buf = ByteData(totalSize);
    int o = 0;

    for (final b in _magic) {
      buf.setUint8(o++, b);
    }
    buf.setUint8(o++, h.version);
    buf.setUint8(o++, h.flags);
    buf.setUint8(o++, h.kdfId);
    buf.setUint16(o, _saltLength, Endian.big); o += 2;
    for (int i = 0; i < _saltLength; i++) {
      buf.setUint8(o++, h.salt[i]);
    }
    buf.setUint32(o, h.opslimit, Endian.big); o += 4;
    buf.setUint32(o, h.memlimit, Endian.big); o += 4;
    buf.setUint8(o++, h.cipherId);
    buf.setUint32(o, h.chunkSize, Endian.big); o += 4;
    for (int i = 0; i < _keyIdLength; i++) {
      buf.setUint8(o++, h.keyIdHint[i]);
    }
    buf.setUint8(o++, h.wraps.length);

    for (final w in h.wraps) {
      buf.setUint8(o++, w.type.code);
      buf.setUint16(o, w.bytes.length, Endian.big); o += 2;
      for (final b in w.bytes) {
        buf.setUint8(o++, b);
      }
    }

    // Encrypted filename (only when flags bit0 = 1).
    if (h.filenameEncrypted && h.encryptedFilename != null) {
      final ef = h.encryptedFilename!;
      buf.setUint16(o, ef.length, Endian.big); o += 2;
      for (final b in ef) {
        buf.setUint8(o++, b);
      }
    }

    for (int i = 0; i < FileHeader.secretstreamHeaderLength; i++) {
      buf.setUint8(o++, h.secretstreamHeader[i]);
    }

    return buf.buffer.asUint8List();
  }

  // Decodes a header from the start of [bytes].
  // Returns (header, bytesConsumed) so the caller knows where the body starts.
  static (FileHeader, int) decodeHeader(Uint8List bytes) {
    if (bytes.length < 56) throw CorruptedFileError('file too short for header');
    final buf = ByteData.sublistView(bytes);
    int o = 0;

    for (int i = 0; i < 5; i++) {
      if (buf.getUint8(o++) != _magic[i]) throw NotALatchFileError();
    }

    final version = buf.getUint8(o++);
    if (version > FileHeader.supportedVersion) throw VersionTooNewError(version);
    final flags = buf.getUint8(o++);
    if (flags & ~FileHeader.knownFlagsMask != 0) {
      throw CorruptedFileError('unknown flag bits $flags');
    }
    final kdfId = buf.getUint8(o++);
    if (kdfId != FileHeader.kdfArgon2id) throw CorruptedFileError('unsupported KDF $kdfId');

    final saltLen = buf.getUint16(o, Endian.big); o += 2;
    if (saltLen != _saltLength) throw CorruptedFileError('unexpected salt length $saltLen');
    if (o + saltLen > bytes.length) throw CorruptedFileError('file too short for salt');
    final salt = Uint8List.fromList(bytes.sublist(o, o + saltLen)); o += saltLen;

    final opslimit = buf.getUint32(o, Endian.big); o += 4;
    final memlimit = buf.getUint32(o, Endian.big); o += 4;
    if (opslimit < FileHeader.minOpslimit || opslimit > FileHeader.maxOpslimit) {
      throw CorruptedFileError('opslimit $opslimit out of range');
    }
    if (memlimit < FileHeader.minMemlimitKib || memlimit > FileHeader.maxMemlimitKib) {
      throw CorruptedFileError('memlimit $memlimit out of range');
    }
    final cipherId = buf.getUint8(o++);
    if (cipherId != FileHeader.cipherXchacha20Poly1305) {
      throw CorruptedFileError('unsupported cipher $cipherId');
    }

    final chunkSize = buf.getUint32(o, Endian.big); o += 4;
    if (chunkSize < FileHeader.minChunkSize || chunkSize > FileHeader.maxChunkSize) {
      throw CorruptedFileError('chunk size $chunkSize out of range');
    }

    if (o + _keyIdLength > bytes.length) throw CorruptedFileError('file too short for key-id');
    final keyIdHint = Uint8List.fromList(bytes.sublist(o, o + _keyIdLength)); o += _keyIdLength;

    final wrapCount = buf.getUint8(o++);
    final wraps = <WrapEntry>[];
    for (int i = 0; i < wrapCount; i++) {
      if (o + 3 > bytes.length) throw CorruptedFileError('truncated wrap list');
      final typeCode = buf.getUint8(o++);
      final wrapLen = buf.getUint16(o, Endian.big); o += 2;
      if (o + wrapLen > bytes.length) throw CorruptedFileError('truncated wrap data');
      final wrapData = Uint8List.fromList(bytes.sublist(o, o + wrapLen)); o += wrapLen;
      final wrapType = WrapType.fromCode(typeCode);
      if (wrapType == null) {
        throw CorruptedFileError('unknown wrap type $typeCode');
      }
      wraps.add(WrapEntry(type: wrapType, bytes: wrapData));
    }

    // Encrypted filename (only when flags bit0 = 1).
    Uint8List? encFilename;
    if ((flags & 0x01) != 0) {
      if (o + 2 > bytes.length) {
        throw CorruptedFileError('truncated enc-filename length');
      }
      final encFilenameLen = buf.getUint16(o, Endian.big); o += 2;
      if (o + encFilenameLen > bytes.length) {
        throw CorruptedFileError('truncated enc-filename data');
      }
      encFilename = Uint8List.fromList(bytes.sublist(o, o + encFilenameLen));
      o += encFilenameLen;
    }

    if (o + FileHeader.secretstreamHeaderLength > bytes.length) {
      throw CorruptedFileError('truncated secretstream header');
    }
    final ssHeader = Uint8List.fromList(
      bytes.sublist(o, o + FileHeader.secretstreamHeaderLength),
    );
    o += FileHeader.secretstreamHeaderLength;

    return (
      FileHeader(
        version: version,
        flags: flags,
        kdfId: kdfId,
        salt: salt,
        opslimit: opslimit,
        memlimit: memlimit,
        cipherId: cipherId,
        chunkSize: chunkSize,
        keyIdHint: keyIdHint,
        wraps: wraps,
        secretstreamHeader: ssHeader,
        encryptedFilename: encFilename,
      ),
      o,
    );
  }
}
