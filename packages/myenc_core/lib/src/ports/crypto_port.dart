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

  // --- X25519 sealed box (spec §3, wrap type 0x03) ---

  /// Seals [plaintext] to [recipientPublicKey] using libsodium crypto_box_seal.
  /// Output: ephemeral-pk (32) ‖ MAC (16) ‖ ciphertext.
  /// For a 32-byte DEK, total output is 80 bytes.
  Uint8List boxSeal(Uint8List plaintext, Uint8List recipientPublicKey);

  /// Opens a sealed box produced by [boxSeal].
  /// Throws [WrongPassphraseError] on authentication failure, consistent with
  /// [secretboxOpen] so callers can distinguish "wrong key" from corruption.
  Uint8List boxSealOpen(Uint8List ciphertext, Uint8List publicKey,
      Uint8List secretKey);
}
