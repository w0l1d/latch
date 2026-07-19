import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import '../../shared/theme/app_theme.dart';

// Target: find KDF params where one derivation takes >= 150ms.
// Floor: opslimit >= 2, memlimit >= 64 MiB (KdfParams.minMemlimitKib).
class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({super.key});

  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _runBenchmark();
  }

  Future<void> _runBenchmark() async {
    if (!mounted) return;
    setState(() => _progress = 0.1);

    KdfParams calibrated;
    try {
      calibrated = await _calibrate();
    } catch (_) {
      calibrated = const KdfParams(opslimit: 3, memlimit: 65536);
    }

    if (!mounted) return;
    setState(() => _progress = 0.9);

    final prefs = await SharedPreferences.getInstance();
    // Always remember what this device calibrated to — the "Auto" KDF preset
    // in Settings restores these values.
    await prefs.setInt('kdf_calibrated_opslimit', calibrated.opslimit);
    await prefs.setInt('kdf_calibrated_memlimit', calibrated.memlimit);
    // Never clobber an existing choice (a preset picked in Settings, or a
    // previous calibration) if onboarding somehow runs again.
    if (!prefs.containsKey('kdf_opslimit')) {
      await prefs.setInt('kdf_opslimit', calibrated.opslimit);
      await prefs.setInt('kdf_memlimit', calibrated.memlimit);
    }

    if (!mounted) return;
    setState(() => _progress = 1.0);

    await Future.delayed(const Duration(milliseconds: 200));
    if (mounted) context.go('/onboarding/loss-moment');
  }

  // Run Argon2id with increasing params until derivation takes >= 150ms.
  // Initialized its own sodium instance — the benchmark intentionally runs on
  // the UI thread to measure real user-perceived cost.
  Future<KdfParams> _calibrate() async {
    const targetMs = 150;
    const testPw = [0x74, 0x65, 0x73, 0x74]; // "test"
    final testSalt = Uint8List(16);

    int ops = KdfParams.minOpslimit;
    int mem = KdfParams.minMemlimitKib; // 64 MiB

    final sodium = await SodiumSumoInit.init();
    final pwhash = sodium.crypto.pwhash;

    // Warm-up pass (JIT / caching effects)
    pwhash.call(
      outLen: 32,
      password: Int8List.fromList(testPw),
      salt: testSalt,
      opsLimit: ops,
      memLimit: mem * 1024,
      alg: CryptoPwhashAlgorithm.argon2id13,
    ).dispose();

    for (int attempt = 0; attempt < 8; attempt++) {
      final sw = Stopwatch()..start();
      pwhash.call(
        outLen: 32,
        password: Int8List.fromList(testPw),
        salt: testSalt,
        opsLimit: ops,
        memLimit: mem * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      ).dispose();
      sw.stop();

      if (!mounted) break;
      setState(() => _progress = 0.1 + (attempt / 8) * 0.75);

      if (sw.elapsedMilliseconds >= targetMs) break;

      // Double opslimit next round (capped at 8).
      ops = (ops * 2).clamp(KdfParams.minOpslimit, 8);
    }

    return KdfParams(opslimit: ops, memlimit: mem);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Text(
                'Getting ready…',
                style: Theme.of(context).textTheme.displayMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: LatchColors.border,
                  color: LatchColors.ink,
                  minHeight: 10,
                  semanticsLabel: 'Benchmarking device performance',
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'A quick one-time check so encryption runs smoothly on your device.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: LatchColors.muted,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Happens once. Stays on your phone.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
