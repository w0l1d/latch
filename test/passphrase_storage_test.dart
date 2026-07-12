import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart'
    show TestFlutterSecureStoragePlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/types/auth_messages.dart';
import 'package:latch/core/passphrase_storage_service.dart';

/// Fake [LocalAuthentication] that returns a configurable boolean.
// ignore: must_be_immutable
class _FakeLocalAuth extends Fake implements LocalAuthentication {
  bool _nextResult = true;
  bool _supported = true;

  void setNextResult(bool v) => _nextResult = v;
  void setSupported(bool v) => _supported = v;

  @override
  Future<bool> get canCheckBiometrics async => _supported;

  @override
  Future<bool> isDeviceSupported() async => _supported;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async =>
      _nextResult;
}

void main() {
  late Map<String, String> inMemoryData;
  late PassphraseStorageService svc;
  late _FakeLocalAuth fakeAuth;

  setUp(() {
    inMemoryData = {};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(inMemoryData);
    fakeAuth = _FakeLocalAuth();
    svc = PassphraseStorageService(
      storage: const FlutterSecureStorage(),
      auth: fakeAuth,
    );
  });

  tearDown(() {
    inMemoryData.clear();
  });

  group('PassphraseStorageService', () {
    test('hasStored returns false when nothing is stored', () async {
      expect(await svc.hasStored(), isFalse);
    });

    test('canAuthenticate delegates to LocalAuth', () async {
      fakeAuth.setSupported(true);
      expect(await svc.canAuthenticate, isTrue);

      fakeAuth.setSupported(false);
      expect(await svc.canAuthenticate, isFalse);
    });

    test('store + hasStored + list cycle', () async {
      await svc.store('report.pdf', 'correct horse battery staple');
      expect(await svc.hasStored(), isTrue);

      final entries = await svc.list();
      expect(entries, hasLength(1));
      expect(entries.first.label, 'report.pdf');
      // list() never exposes the passphrase.
      expect(entries.first.passphrase, isEmpty);
    });

    test('loadWithAuth returns the passphrase on successful auth', () async {
      fakeAuth.setNextResult(true);
      await svc.store('report.pdf', 'correct horse battery staple');

      final pw = await svc.loadWithAuth('report.pdf');
      expect(pw, 'correct horse battery staple');
    });

    test('loadWithAuth returns null on failed auth', () async {
      fakeAuth.setNextResult(false);
      await svc.store('report.pdf', 'correct horse battery staple');

      final pw = await svc.loadWithAuth('report.pdf');
      expect(pw, isNull);
    });

    test('loadWithAuth returns null for unknown label', () async {
      final pw = await svc.loadWithAuth('no-such-file');
      expect(pw, isNull);
    });

    test('delete removes a single entry', () async {
      await svc.store('a.pdf', 'pass1');
      await svc.store('b.pdf', 'pass2');
      expect(await svc.list(), hasLength(2));

      await svc.delete('a.pdf');
      final entries = await svc.list();
      expect(entries, hasLength(1));
      expect(entries.single.label, 'b.pdf');
    });

    test('deleteAll clears everything', () async {
      await svc.store('a.pdf', 'pass1');
      await svc.store('b.pdf', 'pass2');
      await svc.deleteAll();
      expect(await svc.hasStored(), isFalse);
    });

    test('store overwrites an existing label', () async {
      await svc.store('report.pdf', 'old-pass');
      await svc.store('report.pdf', 'new-pass');
      fakeAuth.setNextResult(true);
      expect(await svc.loadWithAuth('report.pdf'), 'new-pass');
    });

    test('store after delete never clobbers another entry (key reuse)', () async {
      fakeAuth.setNextResult(true);
      await svc.store('a.pdf', 'pass-a');
      await svc.store('b.pdf', 'pass-b');
      await svc.delete('a.pdf');
      await svc.store('c.pdf', 'pass-c');

      // Before the max-index fix, c reused b's storage key and both returned pass-c.
      expect(await svc.loadWithAuth('b.pdf'), 'pass-b');
      expect(await svc.loadWithAuth('c.pdf'), 'pass-c');
    });

    test('list survives corrupt meta gracefully', () async {
      inMemoryData['latch_kp_meta'] = 'not-json';
      final entries = await svc.list();
      expect(entries, isEmpty);
    });
  });
}
