import 'package:flutter/material.dart';
import 'core/app_crypto.dart';
import 'core/device_key_service.dart';
import 'core/incoming_file_service.dart';
import 'core/passphrase_storage_service.dart';
import 'core/recipient_key_service.dart';
import 'core/router.dart';
import 'shared/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCrypto.init();
  AppCrypto.passphraseStorage = PassphraseStorageService();
  AppCrypto.deviceKeyService = DeviceKeyService();
  AppCrypto.recipientKeys =
      RecipientKeyService(keygen: AppCrypto.generateShareKeypair);
  runApp(const LatchApp());
}

class LatchApp extends StatefulWidget {
  const LatchApp({super.key});

  @override
  State<LatchApp> createState() => _LatchAppState();
}

class _LatchAppState extends State<LatchApp> {
  late final IncomingFileService _incomingFileService;

  @override
  void initState() {
    super.initState();
    _incomingFileService = IncomingFileService(router: router);
    // Cold-start: a .latch file that launched the app before the Dart engine ran.
    _incomingFileService.handleInitialMedia();
    // Warm-start: subsequent opens while the app is already running.
    _incomingFileService.startListening();
  }

  @override
  void dispose() {
    _incomingFileService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Latch',
      theme: buildTheme(),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
