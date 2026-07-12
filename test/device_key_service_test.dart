import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart'
    show TestFlutterSecureStoragePlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/device_key_service.dart';

void main() {
  late Map<String, String> inMemoryData;
  late DeviceKeyService svc;

  setUp(() {
    inMemoryData = {};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(inMemoryData);
    svc = DeviceKeyService(storage: const FlutterSecureStorage());
  });

  tearDown(() {
    inMemoryData.clear();
  });

  group('DeviceKeyService', () {
    test('hasKey is false before any key is created', () async {
      expect(await svc.hasKey(), isFalse);
    });

    test('getOrCreateKey creates a 32-byte key and persists it', () async {
      final key = await svc.getOrCreateKey();
      expect(key, hasLength(32));
      expect(await svc.hasKey(), isTrue);
    });

    test('getOrCreateKey is stable — same key on every call', () async {
      final first = await svc.getOrCreateKey();
      final second = await svc.getOrCreateKey();
      expect(second, equals(first));
    });

    test('key survives a new service instance (same storage)', () async {
      final key = await svc.getOrCreateKey();
      final svc2 = DeviceKeyService(storage: const FlutterSecureStorage());
      expect(await svc2.getOrCreateKey(), equals(key));
    });

    test('deleteKey removes the key — next call generates a fresh one', () async {
      final first = await svc.getOrCreateKey();
      await svc.deleteKey();
      expect(await svc.hasKey(), isFalse);

      final second = await svc.getOrCreateKey();
      expect(second, hasLength(32));
      expect(second, isNot(equals(first)));
    });

    test('a corrupted stored value is replaced, not returned', () async {
      inMemoryData['latch_device_key'] = 'deadbeef'; // too short
      final key = await svc.getOrCreateKey();
      expect(key, hasLength(32));
      // The corrupt value was overwritten with a full-length key.
      expect(inMemoryData['latch_device_key'], hasLength(64));
    });
  });
}
