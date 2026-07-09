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
  Stream<Uint8List> encrypt({
    required Stream<Uint8List> plaintext,
    required Uint8List passphrase,
    required KdfParams params,
    int flags = 0,
    int chunkSize = FileHeader.defaultChunkSize,
  }) async* {
    final salt = _crypto.randomBytes(16);
    final keyIdHint = _crypto.randomBytes(16);
    final dek = _crypto.randomBytes(DekWrap.dekLength);

    final passphraseWrap = DekWrap.wrapPassphrase(
      crypto: _crypto,
      dek: dek,
      passphrase: passphrase,
      salt: salt,
      opslimit: params.opslimit,
      memlimit: params.memlimit,
    );

    // Encrypt the plaintext stream. The transformer prepends the 24-byte
    // secretstream header as the first bytes of its output.
    final transformer = _crypto.createEncryptTransformer(dek, chunkSize);
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

    // Parse fixed 56-byte prefix
    final fixed = await reader.readExact(56);
    if (fixed == null) throw CorruptedFileError('file too short for header');

    final magic = [0x4C, 0x41, 0x54, 0x43, 0x48];
    for (int i = 0; i < 5; i++) {
      if (fixed[i] != magic[i]) throw CorruptedFileError('invalid magic bytes');
    }

    final version = fixed[5];
    if (version > FileHeader.supportedVersion) throw VersionTooNewError(version);
    final saltLen = (fixed[8] << 8) | fixed[9];
    if (saltLen != 16) throw CorruptedFileError('unexpected salt length $saltLen');
    final salt = fixed.sublist(10, 26);
    final opslimit = _u32(fixed, 26);
    final memlimit = _u32(fixed, 30);
    final chunkSize = _u32(fixed, 35);
    final wrapCount = fixed[55];

    final wraps = <WrapEntry>[];
    for (int i = 0; i < wrapCount; i++) {
      final typeB = await reader.readExact(1);
      final lenB = await reader.readExact(2);
      if (typeB == null || lenB == null) throw CorruptedFileError('truncated wrap list');
      final wrapLen = (lenB[0] << 8) | lenB[1];
      final wrapData = await reader.readExact(wrapLen);
      if (wrapData == null) throw CorruptedFileError('truncated wrap data');
      final wrapType = WrapType.fromCode(typeB[0]);
      if (wrapType != null) wraps.add(WrapEntry(type: wrapType, bytes: wrapData));
    }

    final ssHeader =
        await reader.readExact(FileHeader.secretstreamHeaderLength);
    if (ssHeader == null) throw CorruptedFileError('truncated secretstream header');

    final pw = wraps.where((w) => w.type == WrapType.passphrase).firstOrNull;
    if (pw == null) throw CorruptedFileError('no passphrase wrap found');
    final dek = DekWrap.unwrapPassphrase(
      crypto: _crypto,
      entry: pw,
      passphrase: passphrase,
      salt: salt,
      opslimit: opslimit,
      memlimit: memlimit,
    );

    // Prepend ssHeader to the body and decrypt.
    final bodyWithHeader = _prependStream(ssHeader, reader.remainingStream());
    final transformer = _crypto.createDecryptTransformer(dek, chunkSize);
    yield* bodyWithHeader.transform(transformer);
  }

  static Stream<Uint8List> _prependStream(
      Uint8List prefix, Stream<Uint8List> rest) async* {
    yield prefix;
    yield* rest;
  }

  static int _u32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
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
