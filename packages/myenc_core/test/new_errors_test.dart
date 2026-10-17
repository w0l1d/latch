import 'package:myenc_core/myenc_core.dart';
import 'package:test/test.dart';

/// The two failures folder support adds must be distinguishable *as types*
/// from the failures that already exist, because the user-facing copy differs:
/// "update the app" vs "try again" vs "the file is damaged" (FR-020h).
void main() {
  group('UnknownPayloadKindError', () {
    test('is a LatchError and carries the offending byte', () {
      final e = UnknownPayloadKindError(0x7f);
      expect(e, isA<LatchError>());
      expect(e.kind, 0x7f);
    });

    test('is not confusable with corruption or a wrong passphrase', () {
      final e = UnknownPayloadKindError(0x7f);
      expect(e, isNot(isA<CorruptedFileError>()));
      expect(e, isNot(isA<WrongPassphraseError>()));
      expect(e, isNot(isA<VersionTooNewError>()));
    });

    test('names the value in its message so a bug report is actionable', () {
      expect(UnknownPayloadKindError(0x7f).toString(), contains('0x7f'));
    });
  });

  group('UnsafeArchiveEntryError', () {
    test('is a LatchError and names the offending relative path', () {
      final e = UnsafeArchiveEntryError('../etc/passwd', 'escapes the root');
      expect(e, isA<LatchError>());
      expect(e.entryPath, '../etc/passwd');
      expect(e.reason, 'escapes the root');
    });

    test('names the path and the reason in its message', () {
      final s = UnsafeArchiveEntryError('../x', 'escapes the root').toString();
      expect(s, contains('../x'));
      expect(s, contains('escapes the root'));
    });
  });

  group('InsufficientSpaceError', () {
    test(
      'is a LatchError carrying the shortfall and which volume is short',
      () {
        final e = InsufficientSpaceError(
          shortfallBytes: 1234,
          location: SpaceLocation.staging,
        );
        expect(e, isA<LatchError>());
        expect(e.shortfallBytes, 1234);
        expect(e.location, SpaceLocation.staging);
        expect(e.toString(), contains('staging'));
        expect(e.toString(), contains('1234'));
      },
    );
  });
}
