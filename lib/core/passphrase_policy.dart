import 'package:shared_preferences/shared_preferences.dart';

/// The user's passphrase-storage choice from Settings → "Your passphrase".
///
/// A user who never visited that screen (pref unset) keeps the default
/// behavior: saving is offered, quick unlock works. An explicit
/// "Type it every time" or "Use my password manager" choice strictly
/// disables both storing new passphrases and offering stored ones.
class PassphrasePolicy {
  static const prefKey = 'passphrase_storage_mode';

  /// Whether the UI may store passphrases or offer stored ones.
  static Future<bool> storageAllowed() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(prefKey);
    return mode == null || mode == 'appVault';
  }
}
