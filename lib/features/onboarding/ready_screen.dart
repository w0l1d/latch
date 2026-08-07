import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class ReadyScreen extends StatefulWidget {
  const ReadyScreen({super.key});

  @override
  State<ReadyScreen> createState() => _ReadyScreenState();
}

class _ReadyScreenState extends State<ReadyScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: LatchColors.safe, width: 3),
                ),
                child: ExcludeSemantics(
                  child: const Icon(
                    Icons.check,
                    color: LatchColors.safe,
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'You\'re set.',
                style: Theme.of(context).textTheme.displayLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'No passphrase is saved yet — you\'ll choose one when you lock your first file.',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: LatchColors.muted),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Go to home',
                onPressed: _busy
                    ? null
                    : () async {
                        if (_busy) return;
                        setState(() => _busy = true);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('onboarding_complete', true);
                        if (context.mounted) context.go('/home');
                        if (mounted) setState(() => _busy = false);
                      },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
