import 'package:flutter/material.dart';
import 'package:sodium/sodium_sumo.dart';
import 'core/app_crypto.dart';
import 'core/router.dart';
import 'shared/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sodium = await SodiumSumoInit.init();
  await AppCrypto.init(sodium);
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
