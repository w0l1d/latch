import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class ReadyScreen extends StatelessWidget {
  const ReadyScreen({super.key});

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
                child: const Icon(Icons.check, color: LatchColors.safe, size: 32),
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
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: LatchColors.muted,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Go to home',
                onPressed: () => context.go('/home'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
