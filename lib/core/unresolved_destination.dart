import 'package:shared_preferences/shared_preferences.dart';

import 'saf_bridge.dart';

/// Remembers the folder the user chose for sources whose own folder Android
/// won't reveal.
///
/// Some providers hand the app a document and deliberately nothing about the
/// folder holding it (the picker's Downloads/Images/Videos shortcuts, cloud
/// providers). There is no supported way to recover that folder, so the user
/// is asked where to save instead — and without remembering the answer they
/// would be asked again on every single batch.
///
/// This is NOT a grant cache, and it must not become one. The stored value is
/// a destination *preference*; whether the app may still write there is asked
/// of Android every time via [SafBridge.isTreeGrantLive]. A revoked grant
/// therefore reports unusable and the user is asked again — the failure mode a
/// `folderPath → treeUri` cache would have (silently routing every later batch
/// to Downloads) cannot happen here.
class UnresolvedDestination {
  static const _key = 'unresolved_source_tree_uri';

  /// The remembered destination, but only if Android still honors the grant.
  /// Null means "ask the user".
  static Future<String?> live() async {
    final stored = await _read();
    if (stored == null) return null;
    if (!await SafBridge.isTreeGrantLive(stored)) {
      await forget();
      return null;
    }
    return stored;
  }

  static Future<void> remember(String treeUri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, treeUri);
    } catch (_) {
      // A destination we can't remember only costs an extra prompt later.
    }
  }

  static Future<void> forget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Nothing to do — the liveness check gates every use anyway.
    }
  }

  static Future<String?> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key);
    } catch (_) {
      return null;
    }
  }
}
