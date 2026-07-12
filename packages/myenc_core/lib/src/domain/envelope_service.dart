import 'dart:async';
import 'dart:typed_data';
import '../ports/crypto_port.dart';
import '../format/file_header.dart';
import '../format/myenc_codec.dart';
import '../format/myenc_errors.dart';
import '../format/wrap_entry.dart';
import 'dek_wrap.dart';
import 'kdf_params.dart';

class EnvelopeService {
  final CryptoPort _crypto;

  EnvelopeService(this._crypto);

  /// Encrypts [plaintext] and yields: encoded FileHeader + encrypted body chunks.
  ///
  /// If [filename] is set and &flags includes bit0, the filename is encrypted
  /// with the DEK and stored in the header (spec §6, §7.15, and §8).
  Stream<Uint8List> encrypt({
    required Stream<Uint8List> plaintext,
    required Uint8List passphrase,
    required KdfParams params,
    int flags = 0,
    int chunkSize = FileHeader.defaultChunkSize,
    String? filename,
    Uint8List? keyIdHint,
  }) async* {
    if (!params.meetsFloor()) {
      throw CorruptedFileError('KDF params below security floor');
    }
    if (keyIdHint != null && keyIdHint.length != 16) {
      throw CorruptedFileError('key-id hint must be 16 bytes');
    }
    final salt = _crypto.randomBytes(16);
    keyIdHint ??= _crypto.randomBytes(16);
    final dek = _crypto.randomBytes(DekWrap.dekLength);

    final passphraseWrap = DekWrap.wrapPassphrase(
      crypto: _crypto,
      dek: dek,
      passphrase: passphrase,
      salt: salt,
      opslimit: params.opslimit,
      memlimit: params.memlimit,
    );

    // Encrypt the filename with the DEK before zeroizing.
    Uint8List? encFilename;
    if ((flags & 0x01) != 0 && filename != null && filename.isNotEmpty) {
      encFilename = _crypto.secretboxSeal(
        Uint8List.fromList(filename.codeUnits),
        dek,
      );
    }

    // Encrypt the plaintext stream. The transformer prepends the 24-byte
    // secretstream header as the first bytes of its output.
    final transformer = _crypto.createEncryptTransformer(dek, chunkSize);
    // DEK has been copied to guarded memory by SecureKey; zero the plain copy.
    dek.fillRange(0, dek.length, 0);
    final encryptedStream = plaintext.transform(transformer);

    // Extract the secretstream header from the transformer's output so it can
    // be stored in the FileHeader, which must be emitted first.
    final encReader = _StreamReader(encryptedStream);
    final ssHeader =
        await encReader.readExact(_crypto.secretstreamHeaderBytes);
    if (ssHeader == null) throw CorruptedFileError('encrypt produced no output');

    final header = FileHeader(
      version: FileHeader.supportedVersion,
      flags: flags,
      kdfId: FileHeader.kdfArgon2id,
      salt: salt,
      opslimit: params.opslimit,
      memlimit: params.memlimit,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: chunkSize,
      keyIdHint: keyIdHint,
      wraps: [passphraseWrap],
      secretstreamHeader: ssHeader,
      encryptedFilename: encFilename,
    );

    yield MyencCodec.encodeHeader(header);
    await for (final chunk in encReader.remainingStream()) {
      yield chunk;
    }
  }

  /// Decrypts a [ciphertext] stream back to plaintext.
  ///
  /// Throws [WrongPassphraseError], [CorruptedFileError], or [VersionTooNewError].
  Stream<Uint8List> decrypt({
    required Stream<Uint8List> ciphertext,
    required Uint8List passphrase,
  }) async* {
    final reader = _StreamReader(ciphertext);
    final hdr = await _readHeader(reader);
    final dek = _unwrapDek(hdr, passphrase);

    // Prepend the ss header to the body and decrypt.
    final bodyWithHeader = _prependStream(hdr.secretstreamHeader, reader.remainingStream());
    final transformer = _crypto.createDecryptTransformer(dek, hdr.chunkSize);
    // DEK has been copied to guarded memory by SecureKey; zero the plain copy.
    dek.fillRange(0, dek.length, 0);
    yield* bodyWithHeader.transform(transformer);
  }

  /// Changes the passphrase of an encrypted stream WITHOUT re-encrypting the
  /// body (spec: "change passphrase = re-wrap DEK only"). Unwraps the DEK with
  /// [oldPassphrase], re-wraps it under a fresh Argon2id KEK derived from
  /// [newPassphrase] with a new random salt and [params], then emits the
  /// rewritten header followed by the body bytes verbatim. The DEK — and
  /// therefore the body ciphertext and encrypted filename — never changes.
  ///
  /// [keyIdHint] optionally replaces the header's key-id (16 bytes) so the
  /// file can point at a different stored-passphrase entry; null keeps the
  /// existing one.
  ///
  /// Throws [WrongPassphraseError] if [oldPassphrase] is wrong.
  Stream<Uint8List> changePassphrase({
    required Stream<Uint8List> ciphertext,
    required Uint8List oldPassphrase,
    required Uint8List newPassphrase,
    required KdfParams params,
    Uint8List? keyIdHint,
  }) async* {
    if (!params.meetsFloor()) {
      throw CorruptedFileError('KDF params below security floor');
    }
    if (keyIdHint != null && keyIdHint.length != 16) {
      throw CorruptedFileError('key-id hint must be 16 bytes');
    }
    final reader = _StreamReader(ciphertext);
    final hdr = await _readHeader(reader);
    final dek = _unwrapDek(hdr, oldPassphrase);

    try {
      final newSalt = _crypto.randomBytes(16);
      final newWrap = DekWrap.wrapPassphrase(
        crypto: _crypto,
        dek: dek,
        passphrase: newPassphrase,
        salt: newSalt,
        opslimit: params.opslimit,
        memlimit: params.memlimit,
      );

      // Replace the passphrase wrap; every other wrap (hardware, recipient)
      // still wraps the same DEK and is carried over untouched.
      final newWraps = [
        for (final w in hdr.wraps)
          if (w.type == WrapType.passphrase) newWrap else w,
      ];

      yield MyencCodec.encodeHeader(FileHeader(
        version: hdr.version,
        flags: hdr.flags,
        kdfId: hdr.kdfId,
        salt: newSalt,
        opslimit: params.opslimit,
        memlimit: params.memlimit,
        cipherId: hdr.cipherId,
        chunkSize: hdr.chunkSize,
        keyIdHint: keyIdHint ?? hdr.keyIdHint,
        wraps: newWraps,
        secretstreamHeader: hdr.secretstreamHeader,
        encryptedFilename: hdr.encryptedFilename,
      ));
    } finally {
      dek.fillRange(0, dek.length, 0);
    }

    // Body passthrough — ciphertext unchanged under the unchanged DEK.
    yield* reader.remainingStream();
  }

  /// Reads and decodes the full header from [reader], leaving the reader
  /// positioned at the first body byte.
  Future<FileHeader> _readHeader(_StreamReader reader) async {
    // Read the fixed 56-byte prefix.
    final fixed = await reader.readExact(56);
    if (fixed == null) throw CorruptedFileError('file too short for header');

    final wrapCount = fixed[55];
    final flags = fixed[6];
    final wrapChunks = <Uint8List>[fixed];

    // Read the variable-length wrap list.
    for (int i = 0; i < wrapCount; i++) {
      final typeB = await reader.readExact(1);
      final lenB = await reader.readExact(2);
      if (typeB == null || lenB == null) throw CorruptedFileError('truncated wrap list');
      final wrapLen = (lenB[0] << 8) | lenB[1];
      final wrapData = await reader.readExact(wrapLen);
      if (wrapData == null) throw CorruptedFileError('truncated wrap data');
      wrapChunks.add(typeB);
      wrapChunks.add(lenB);
      wrapChunks.add(wrapData);
    }

    // Encrypted filename (only when flags bit0 = 1).
    if ((flags & 0x01) != 0) {
      final encLenB = await reader.readExact(2);
      if (encLenB == null) throw CorruptedFileError('truncated enc-filename length');
      final encFilenameLen = (encLenB[0] << 8) | encLenB[1];
      final encFilename = await reader.readExact(encFilenameLen);
      if (encFilename == null) throw CorruptedFileError('truncated enc-filename data');
      wrapChunks.add(encLenB);
      wrapChunks.add(encFilename);
    }

    // Read the secretstream header.
    final ssHeader =
        await reader.readExact(FileHeader.secretstreamHeaderLength);
    if (ssHeader == null) throw CorruptedFileError('truncated secretstream header');
    wrapChunks.add(ssHeader);

    // Assemble the full header buffer and decode via MyencCodec (single parser).
    final totalLen = wrapChunks.fold<int>(0, (s, c) => s + c.length);
    final headerBuf = Uint8List(totalLen);
    int off = 0;
    for (final c in wrapChunks) {
      headerBuf.setRange(off, off + c.length, c);
      off += c.length;
    }
    final (hdr, _) = MyencCodec.decodeHeader(headerBuf);
    return hdr;
  }

  /// Unwraps the DEK from [hdr]'s passphrase wrap. The caller owns the
  /// returned bytes and must zeroize them.
  Uint8List _unwrapDek(FileHeader hdr, Uint8List passphrase) {
    final pw = hdr.wraps.where((w) => w.type == WrapType.passphrase).firstOrNull;
    if (pw == null) throw CorruptedFileError('no passphrase wrap found');
    return DekWrap.unwrapPassphrase(
      crypto: _crypto,
      entry: pw,
      passphrase: passphrase,
      salt: hdr.salt,
      opslimit: hdr.opslimit,
      memlimit: hdr.memlimit,
    );
  }

  /// Decrypts the encrypted filename from [header] using the given [dek].
  /// Returns null if the header has no encrypted filename.
  static Uint8List? decryptFilename({
    required CryptoPort crypto,
    required FileHeader header,
    required Uint8List dek,
  }) {
    if (header.encryptedFilename == null) return null;
    return crypto.secretboxOpen(header.encryptedFilename!, dek);
  }

  static Stream<Uint8List> _prependStream(
      Uint8List prefix, Stream<Uint8List> rest) async* {
    yield prefix;
    yield* rest;
  }
}

// Reads exact byte counts from a chunked stream, then allows resuming as a stream.
class _StreamReader {
  final StreamIterator<Uint8List> _it;
  final _buf = <Uint8List>[];
  var _bufLen = 0;
  var _done = false;

  _StreamReader(Stream<Uint8List> stream) : _it = StreamIterator(stream);

  Future<Uint8List?> readExact(int n) async {
    while (_bufLen < n) {
      if (_done) return null;
      if (!await _it.moveNext()) { _done = true; return null; }
      _buf.add(_it.current);
      _bufLen += _it.current.length;
    }
    return _takeFront(n);
  }

  Stream<Uint8List> remainingStream() async* {
    if (_bufLen > 0) yield _takeFront(_bufLen);
    if (!_done) {
      while (await _it.moveNext()) {
        yield _it.current;
      }
    }
  }

  Uint8List _takeFront(int n) {
    final out = Uint8List(n);
    int written = 0;
    while (written < n) {
      final front = _buf.first;
      final need = n - written;
      if (front.length <= need) {
        out.setRange(written, written + front.length, front);
        written += front.length;
        _bufLen -= front.length;
        _buf.removeAt(0);
      } else {
        out.setRange(written, n, front);
        _buf[0] = Uint8List.sublistView(front, need);
        _bufLen -= need;
        written = n;
      }
    }
    return out;
  }
}
