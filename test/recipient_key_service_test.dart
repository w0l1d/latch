import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart'
    show TestFlutterSecureStoragePlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/recipient_key_service.dart';

void main() {
  late Map<String, String> inMemoryData;
  late int keygenCalls;
  late RecipientKeyService svc;

  ShareKeypair fakeKeypair(int seed) => (
    publicKey: Uint8List.fromList(List.generate(32, (i) => (i + seed) & 0xff)),
    secretKey: Uint8List.fromList(List.generate(32, (i) => (i + seed) ^ 0xaa)),
  );

  setUp(() {
    inMemoryData = {};
    keygenCalls = 0;
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      inMemoryData,
    );
    svc = RecipientKeyService(
      storage: const FlutterSecureStorage(),
      keygen: () async => fakeKeypair(++keygenCalls),
    );
  });

  tearDown(() {
    inMemoryData.clear();
  });

  group('my keypair', () {
    test('hasKeyPair is false before any keypair is created', () async {
      expect(await svc.hasKeyPair(), isFalse);
      expect(await svc.publicKeyHex(), isNull);
    });

    test('getOrCreateKeyPair generates once and persists as hex', () async {
      final kp = await svc.getOrCreateKeyPair();
      expect(kp.publicKey, hasLength(32));
      expect(kp.secretKey, hasLength(32));
      expect(keygenCalls, 1);
      expect(await svc.hasKeyPair(), isTrue);
      expect(inMemoryData['latch_share_pk'], hasLength(64));
      expect(inMemoryData['latch_share_sk'], hasLength(64));
    });

    test(
      'getOrCreateKeyPair is stable — same keypair, no regeneration',
      () async {
        final first = await svc.getOrCreateKeyPair();
        final second = await svc.getOrCreateKeyPair();
        expect(second.publicKey, equals(first.publicKey));
        expect(second.secretKey, equals(first.secretKey));
        expect(keygenCalls, 1);
      },
    );

    test('keypair survives a new service instance (same storage)', () async {
      final kp = await svc.getOrCreateKeyPair();
      final svc2 = RecipientKeyService(
        storage: const FlutterSecureStorage(),
        keygen: () async => fakeKeypair(99),
      );
      final again = await svc2.getOrCreateKeyPair();
      expect(again.publicKey, equals(kp.publicKey));
      expect(again.secretKey, equals(kp.secretKey));
    });

    test('publicKeyHex matches the stored public key bytes', () async {
      final kp = await svc.getOrCreateKeyPair();
      final hex = await svc.publicKeyHex();
      expect(hex, isNotNull);
      expect(decodePublicKeyHex(hex!), equals(kp.publicKey));
    });

    test(
      'deleteKeyPair removes it — next call generates a fresh one',
      () async {
        final first = await svc.getOrCreateKeyPair();
        await svc.deleteKeyPair();
        expect(await svc.hasKeyPair(), isFalse);

        final second = await svc.getOrCreateKeyPair();
        expect(keygenCalls, 2);
        expect(second.publicKey, isNot(equals(first.publicKey)));
      },
    );

    test('a corrupted stored value is regenerated, not returned', () async {
      inMemoryData['latch_share_pk'] = 'deadbeef'; // too short
      inMemoryData['latch_share_sk'] = 'deadbeef';
      final kp = await svc.getOrCreateKeyPair();
      expect(kp.publicKey, hasLength(32));
      expect(keygenCalls, 1);
      expect(inMemoryData['latch_share_pk'], hasLength(64));
    });

    test(
      'without a generator, first use throws instead of storing junk',
      () async {
        final bare = RecipientKeyService(storage: const FlutterSecureStorage());
        expect(bare.getOrCreateKeyPair, throwsStateError);
        expect(await bare.hasKeyPair(), isFalse);
      },
    );
  });

  group('recipient address book', () {
    final aliceHex = 'ab' * 32;
    final bobHex = 'cd' * 32;

    test('starts empty', () async {
      expect(await svc.listRecipients(), isEmpty);
    });

    test('store + list round-trips label and key', () async {
      await svc.storeRecipient('Alice', aliceHex);
      await svc.storeRecipient('Bob', bobHex);

      final list = await svc.listRecipients();
      expect(list, hasLength(2));
      expect(list[0].label, 'Alice');
      expect(list[0].publicKeyHex, aliceHex);
      expect(list[1].label, 'Bob');
      expect(list[1].publicKeyHex, bobHex);
    });

    test('storing an existing label overwrites its key', () async {
      await svc.storeRecipient('Alice', aliceHex);
      await svc.storeRecipient('Alice', bobHex);

      final list = await svc.listRecipients();
      expect(list, hasLength(1));
      expect(list.single.publicKeyHex, bobHex);
    });

    test('uppercase hex is normalized to lowercase', () async {
      await svc.storeRecipient('Alice', aliceHex.toUpperCase());
      final list = await svc.listRecipients();
      expect(list.single.publicKeyHex, aliceHex);
    });

    test('delete removes only the named recipient', () async {
      await svc.storeRecipient('Alice', aliceHex);
      await svc.storeRecipient('Bob', bobHex);
      await svc.deleteRecipient('Alice');

      final list = await svc.listRecipients();
      expect(list, hasLength(1));
      expect(list.single.label, 'Bob');
    });

    test('deleting an unknown label is a no-op', () async {
      await svc.storeRecipient('Alice', aliceHex);
      await svc.deleteRecipient('Nobody');
      expect(await svc.listRecipients(), hasLength(1));
    });

    test('invalid hex is rejected with ArgumentError', () async {
      // Too short, too long, and non-hex characters.
      expect(() => svc.storeRecipient('X', 'ab' * 31), throwsArgumentError);
      expect(() => svc.storeRecipient('X', 'ab' * 33), throwsArgumentError);
      expect(() => svc.storeRecipient('X', 'zz' * 32), throwsArgumentError);
      expect(await svc.listRecipients(), isEmpty);
    });
  });

  group('decodePublicKeyHex', () {
    test('decodes 64 hex chars to 32 bytes', () {
      final bytes = decodePublicKeyHex('00ff' * 16);
      expect(bytes, hasLength(32));
      expect(bytes[0], 0x00);
      expect(bytes[1], 0xff);
    });

    test('rejects malformed input', () {
      expect(() => decodePublicKeyHex('short'), throwsArgumentError);
      expect(() => decodePublicKeyHex('gg' * 32), throwsArgumentError);
    });
  });
}
