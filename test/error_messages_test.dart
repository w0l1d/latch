import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:latch/shared/error_messages.dart';

void main() {
  group('userMessageForError — folder payload failures', () {
    test('unknown payload kind reads as "update the app", not "damaged"', () {
      final msg = userMessageForError(UnknownPayloadKindError(0x7f));
      expect(msg.toLowerCase(), contains('newer version'));
      expect(msg.toLowerCase(), isNot(contains('damaged')));
      expect(msg.toLowerCase(), isNot(contains('passphrase')));
    });

    test('unknown payload kind is distinct from corruption copy', () {
      expect(
        userMessageForError(UnknownPayloadKindError(0x7f)),
        isNot(userMessageForError(CorruptedFileError('bad tag'))),
      );
    });

    test('unsafe archive entry names the offending entry to the user', () {
      final msg = userMessageForError(
        UnsafeArchiveEntryError('../etc/passwd', 'escapes the folder'),
      );
      expect(msg, contains('../etc/passwd'));
    });

    // The worker isolate reports failures as strings, so the string-form path
    // must recognise the new errors too — otherwise a folder restore failure
    // degrades to the generic "Something went wrong".
    test('recognises the worker string form of an unknown payload kind', () {
      final msg = userMessageForError(UnknownPayloadKindError(0x7f).toString());
      expect(msg.toLowerCase(), contains('newer version'));
    });

    test('recognises the worker string form of an unsafe entry', () {
      final msg = userMessageForError(
        UnsafeArchiveEntryError('../x', 'escapes the folder').toString(),
      );
      expect(msg, isNot(contains('Something went wrong')));
    });

    test('no raw exception text leaks into the unknown-kind message', () {
      expect(
        userMessageForError(UnknownPayloadKindError(0x7f)),
        isNot(contains('UnknownPayloadKindError')),
      );
    });
  });

  group('userMessageForError — existing behaviour is unchanged', () {
    test('wrong passphrase', () {
      expect(
        userMessageForError(WrongPassphraseError()),
        contains('Incorrect passphrase'),
      );
    });
    test('corrupt file', () {
      expect(
        userMessageForError(CorruptedFileError('tag')),
        contains('damaged'),
      );
    });
    test('unrecognised error falls back to the generic message', () {
      expect(
        userMessageForError(StateError('nope')),
        contains('Something went wrong'),
      );
    });
  });

  group('userMessageForError — InsufficientSpaceError', () {
    test('typed: names the short location and the shortfall', () {
      final dest = userMessageForError(
        InsufficientSpaceError(
          shortfallBytes: 3 * 1024 * 1024,
          location: SpaceLocation.destination,
        ),
      );
      expect(dest, contains('destination'));
      expect(dest, contains('3.0 MB'));
      expect(dest, contains('not changed'));
      final stage = userMessageForError(
        InsufficientSpaceError(
          shortfallBytes: 10,
          location: SpaceLocation.staging,
        ),
      );
      expect(stage, contains('working storage'));
      expect(stage, contains('10 B'));
    });

    test('string form from the worker keeps location and size', () {
      final text = InsufficientSpaceError(
        shortfallBytes: 2048,
        location: SpaceLocation.staging,
      ).toString();
      final m = userMessageForError(text);
      expect(m, contains('working storage'));
      expect(m, contains('2.0 KB'));
    });

    test('unknown shortfall omits the amount', () {
      final m = userMessageForError(
        InsufficientSpaceError(
          shortfallBytes: 0,
          location: SpaceLocation.destination,
        ),
      );
      expect(m, isNot(contains(' by about')));
    });
  });

  group('userMessageForError — VerificationFailedError', () {
    test('typed: says the copy was discarded and the original kept', () {
      final m = userMessageForError(VerificationFailedError('differs'));
      expect(m, contains('could not be verified'));
      expect(m, contains('original was kept'));
    });

    test('string form from the worker gets the same copy', () {
      final typed = userMessageForError(VerificationFailedError('differs'));
      final text = userMessageForError(
        VerificationFailedError('differs').toString(),
      );
      expect(text, typed);
    });

    test('is not mistaken for a wrong passphrase or corruption', () {
      final m = userMessageForError(VerificationFailedError('differs'));
      expect(m.toLowerCase(), isNot(contains('passphrase')));
      expect(m.toLowerCase(), isNot(contains('damaged')));
    });
  });
}
