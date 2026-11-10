import 'package:shared_preferences/shared_preferences.dart';
import 'bulk_plan.dart' show BulkKeyMode, BulkPlacement;

/// Preferences for bulk encryption. Preferences, not secrets; a store that
/// can't be read or written falls back to the safe default and never throws.
class BulkSettings {
  static const keyModeKey = 'bulk.keyMode';
  static const outputPlacementKey = 'bulk.outputPlacement';

  static Future<BulkKeyMode> keyMode() async =>
      _read(keyModeKey, BulkKeyMode.values, BulkKeyMode.perFile);

  static Future<void> setKeyMode(BulkKeyMode mode) =>
      _write(keyModeKey, mode.name);

  static Future<BulkPlacement> outputPlacement() async => _read(
    outputPlacementKey,
    BulkPlacement.values,
    BulkPlacement.mirroredFolder,
  );

  static Future<void> setOutputPlacement(BulkPlacement placement) =>
      _write(outputPlacementKey, placement.name);

  static Future<T> _read<T extends Enum>(
    String key,
    List<T> values,
    T fallback,
  ) async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(key);
      for (final v in values) {
        if (v.name == stored) return v;
      }
    } catch (_) {
      // Unreadable store: the default is the more conservative choice.
    }
    return fallback;
  }

  static Future<void> _write(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } catch (_) {
      // Not persisted; the next read returns the default.
    }
  }
}
