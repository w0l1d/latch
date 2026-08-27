import 'myenc_errors.dart';

/// One known `.latch` container version and what it can carry.
///
/// Entries exist only as members of [FormatVersionRegistry.all] — the
/// constructor is private, so no caller can conjure an entry for a version
/// the build does not know (a second source of truth). A future version
/// declares its capabilities by adding a defaulted `final` field here; no
/// call site changes.
class FormatVersion {
  /// The value written into the container's version byte. 1–255.
  final int number;

  const FormatVersion._({required this.number});
}

/// The single authority on which `.latch` format versions this build knows.
///
/// Every version decision routes through this table (specs/002): the codec's
/// decode gate asks [require], writers stamp [writeDefault], and the freeze
/// guard asserts against [firstUnknown]. Nothing else compares against a
/// version literal.
class FormatVersionRegistry {
  /// The frozen v1 layout, described normatively by docs/FORMAT.md §2.
  /// The only version this build knows.
  static const FormatVersion v1 = FormatVersion._(number: 1);

  /// Every known version, keyed by [FormatVersion.number].
  static const Map<int, FormatVersion> all = {1: v1};

  /// Resolves [n] to its entry, or refuses it.
  ///
  /// The decode path's only version decision: an unknown byte — 0, or
  /// anything from [firstUnknown] through 255 — throws rather than being
  /// guessed at. Never returns null, never substitutes a nearest match.
  static FormatVersion require(int n) {
    final entry = all[n];
    if (entry == null) throw VersionTooNewError(n);
    return entry;
  }

  /// The version stamped on newly written containers.
  ///
  /// Stated in its own right, deliberately not derived from [all]'s maximum:
  /// raising the read boundary must never move what new files are written
  /// as, or containers stop being openable by installs that could read them.
  static const FormatVersion writeDefault = v1;

  /// The smallest positive integer with no entry in [all]. Today 2.
  ///
  /// Derived, never stored, so it cannot disagree with [require]. Computing
  /// it as the *smallest* absent integer — not `max + 1` — keeps it pointing
  /// at a real hole if a gap is ever introduced.
  static int get firstUnknown {
    var n = 1;
    while (all.containsKey(n)) {
      n++;
    }
    return n;
  }
}
