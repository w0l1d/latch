import 'dart:typed_data';
import 'file_header.dart';
import 'format_strategy_v1.dart';
import 'format_version.dart';

/// The magic prefix shared by every `.latch` version: "LATCH".
class MyencCodecMagic {
  static const List<int> bytes = [0x4C, 0x41, 0x54, 0x43, 0x48];
}

/// One version's header layout. Pure: no I/O, no randomness, no shared
/// mutable state — [decode] and [encode] are inverses for any header the
/// version can produce.
///
/// [decode] starts at [offset] (the byte right after the version byte,
/// itself already consumed by the façade) and returns the header plus the
/// absolute number of bytes consumed from the start of the buffer.
abstract interface class FormatVersionStrategy {
  (FileHeader, int) decode(Uint8List bytes, int offset);
  Uint8List encode(FileHeader header);
}

/// Keyed by the same version numbers `FormatVersionRegistry.all` knows.
/// specs/003's totality invariant: this table's key set and the registry's
/// value set must always agree, in both directions — a registry entry with
/// no strategy (or vice versa) is a build-time test failure, not a runtime
/// surprise on user data.
final Map<int, FormatVersionStrategy> formatVersionStrategies = {
  FormatVersionRegistry.v1.number: const V1Strategy(),
};
