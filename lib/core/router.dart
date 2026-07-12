import 'package:go_router/go_router.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/onboarding/how_it_works_screen.dart';
import '../features/onboarding/device_check_screen.dart';
import '../features/onboarding/loss_moment_screen.dart';
import '../features/onboarding/ready_screen.dart';
import '../features/home/home_screen.dart';
import '../features/encrypt/encrypt_pick_screen.dart';
import '../features/encrypt/encrypt_passphrase_screen.dart';
import '../features/encrypt/encrypt_options_screen.dart';
import '../features/encrypt/encrypt_review_screen.dart';
import '../features/encrypt/encrypt_progress_screen.dart';
import '../features/encrypt/encrypt_success_screen.dart';
import '../features/decrypt/decrypt_pick_screen.dart';
import '../features/decrypt/decrypt_passphrase_screen.dart';
import '../features/decrypt/decrypt_progress_screen.dart';
import '../features/decrypt/decrypt_success_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/passphrase_storage_screen.dart';
import '../features/settings/change_passphrase_screen.dart';
import '../features/settings/secure_delete_screen.dart';
import '../features/settings/sharing_keys_screen.dart';
import '../features/settings/add_recipient_screen.dart';

final router = GoRouter(
  initialLocation: '/onboarding/welcome',
  routes: [
    GoRoute(path: '/onboarding/welcome', builder: (ctx, st) => const WelcomeScreen()),
    GoRoute(path: '/onboarding/how-it-works', builder: (ctx, st) => const HowItWorksScreen()),
    GoRoute(path: '/onboarding/device-check', builder: (ctx, st) => const DeviceCheckScreen()),
    GoRoute(path: '/onboarding/loss-moment', builder: (ctx, st) => const LossMomentScreen()),
    GoRoute(path: '/onboarding/ready', builder: (ctx, st) => const ReadyScreen()),
    GoRoute(path: '/home', builder: (ctx, st) => const HomeScreen()),
    GoRoute(path: '/encrypt/pick', builder: (ctx, st) => const EncryptPickScreen()),
    GoRoute(
      path: '/encrypt/passphrase',
      builder: (ctx, state) {
        final extra = state.extra;
        final files = extra is List<String> ? extra : <String>[];
        return EncryptPassphraseScreen(files: files);
      },
    ),
    GoRoute(
      path: '/encrypt/options',
      builder: (ctx, state) {
        final extra = state.extra;
        final map = extra is Map<String, dynamic> ? extra : <String, dynamic>{};
        return EncryptOptionsScreen(
          files: map['files'] is List<String> ? map['files'] as List<String> : [],
          passphrase: map['passphrase'] is String ? map['passphrase'] as String : '',
          keyIdHex: map['keyIdHex'] is String ? map['keyIdHex'] as String? : null,
        );
      },
    ),
    GoRoute(
      path: '/encrypt/review',
      builder: (ctx, state) {
        final extra = state.extra;
        final map = extra is Map<String, dynamic> ? extra : <String, dynamic>{};
        return EncryptReviewScreen(
          files: map['files'] is List<String> ? map['files'] as List<String> : [],
          passphrase: map['passphrase'] is String ? map['passphrase'] as String : '',
          deleteOriginals: map['deleteOriginals'] is bool ? map['deleteOriginals'] as bool : false,
          outputDir: map['outputDir'] is String ? map['outputDir'] as String? : null,
          keyIdHex: map['keyIdHex'] is String ? map['keyIdHex'] as String? : null,
        );
      },
    ),
    GoRoute(
      path: '/encrypt/progress',
      builder: (ctx, state) {
        final extra = state.extra;
        final map = extra is Map<String, dynamic> ? extra : <String, dynamic>{};
        return EncryptProgressScreen(
          files: map['files'] is List<String> ? map['files'] as List<String> : [],
          passphrase: map['passphrase'] is String ? map['passphrase'] as String : '',
          deleteOriginals: map['deleteOriginals'] is bool ? map['deleteOriginals'] as bool : false,
          outputDir: map['outputDir'] is String ? map['outputDir'] as String? : null,
          keyIdHex: map['keyIdHex'] is String ? map['keyIdHex'] as String? : null,
        );
      },
    ),
    GoRoute(
      path: '/encrypt/success',
      builder: (ctx, state) {
        final extra = state.extra;
        final files = extra is List<String> ? extra : <String>[];
        return EncryptSuccessScreen(files: files);
      },
    ),
    GoRoute(path: '/decrypt/pick', builder: (ctx, st) => const DecryptPickScreen()),
    GoRoute(
      path: '/decrypt/passphrase',
      builder: (ctx, state) {
        final extra = state.extra;
        final files = extra is List<String> ? extra : <String>[];
        return DecryptPassphraseScreen(files: files);
      },
    ),
    GoRoute(
      path: '/decrypt/progress',
      builder: (ctx, state) {
        final extra = state.extra;
        final map = extra is Map<String, dynamic> ? extra : <String, dynamic>{};
        return DecryptProgressScreen(
          files: map['files'] is List<String> ? map['files'] as List<String> : [],
          passphrase: map['passphrase'] is String ? map['passphrase'] as String : '',
        );
      },
    ),
    GoRoute(
      path: '/decrypt/success',
      builder: (ctx, state) {
        final extra = state.extra;
        final files = extra is List<String> ? extra : <String>[];
        return DecryptSuccessScreen(files: files);
      },
    ),
    GoRoute(path: '/settings', builder: (ctx, st) => const SettingsScreen()),
    GoRoute(path: '/settings/passphrase-storage', builder: (ctx, st) => const PassphraseStorageScreen()),
    GoRoute(path: '/settings/change-passphrase', builder: (ctx, st) => const ChangePassphraseScreen()),
    GoRoute(path: '/settings/secure-delete', builder: (ctx, st) => const SecureDeleteScreen()),
    GoRoute(path: '/settings/sharing-keys', builder: (ctx, st) => const SharingKeysScreen()),
    GoRoute(path: '/settings/add-recipient', builder: (ctx, st) => const AddRecipientScreen()),
  ],
);
