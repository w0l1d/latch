import 'dart:async';
import 'dart:typed_data';

abstract interface class CryptoPort {
  Uint8List randomBytes(int length);

  Uint8List argon2idDerive({
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
    required int outputLength,
  });

  // Output: nonce(24B) + MAC(16B) + ciphertext.
  Uint8List secretboxSeal(Uint8List plaintext, Uint8List key);

  // Throws WrongPassphraseError on authentication failure.
  Uint8List secretboxOpen(Uint8List ciphertext, Uint8List key);

  // Always 24 for XChaCha20-Poly1305 secretstream.
  int get secretstreamHeaderBytes;

  // Input: plaintext chunks of any size.
  // Output: secretstream header (24B) followed by encrypted chunks.
  // Plaintext is buffered to [chunkSize]-byte blocks; last block carries FINAL tag.
  StreamTransformer<Uint8List, Uint8List> createEncryptTransformer(
      Uint8List key, int chunkSize);

  // Input: secretstream header (24B) followed by encrypted chunks.
  // Output: plaintext chunks.
  // Throws CorruptedFileError on authentication failure or missing FINAL tag.
  StreamTransformer<Uint8List, Uint8List> createDecryptTransformer(
      Uint8List key, int chunkSize);
}
