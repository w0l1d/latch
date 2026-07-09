import 'package:flutter/material.dart';
import 'core/app_crypto.dart';
import 'core/router.dart';
import 'shared/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCrypto.init();
  runApp(const LatchApp());
}

class LatchApp extends StatelessWidget {
  const LatchApp({super.key});

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
