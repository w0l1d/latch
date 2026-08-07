import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: () => context.push('/settings'),
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Settings',
                  ),
                ],
              ),
              const Spacer(),
              ExcludeSemantics(
                child: const Icon(
                  Icons.lock_outline,
                  size: 56,
                  color: LatchColors.ink,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'What would you\nlike to protect?',
                style: Theme.of(context).textTheme.displayMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Everything happens on this phone. There\'s nothing to sign in to.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Encrypt files',
                onPressed: () => context.push('/encrypt/pick'),
              ),
              const SizedBox(height: 12),
              LatchSecondaryButton(
                label: 'Decrypt a file',
                onPressed: () => context.push('/decrypt/pick'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
