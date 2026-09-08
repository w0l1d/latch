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
}
