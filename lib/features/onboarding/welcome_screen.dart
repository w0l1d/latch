import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            children: [
              const Spacer(),
              _LockIcon(),
              const SizedBox(height: 32),
              Text(
                'Lock your files.\nKeep the key.',
                style: Theme.of(context).textTheme.displayLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Text(
                'Encrypt files right here on your phone. No account, no cloud — nothing leaves this device.',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: LatchColors.muted),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Get started',
                onPressed: () => context.go('/onboarding/how-it-works'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _LockIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: LatchColors.background,
        border: Border.all(color: LatchColors.ink, width: 2.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Icon(Icons.lock_outline, size: 38, color: LatchColors.ink),
    );
  }
}
