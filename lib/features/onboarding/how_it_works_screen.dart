import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('How it works', style: Theme.of(context).textTheme.displayMedium),
              const SizedBox(height: 36),
              _Step(
                number: '1',
                text: 'One passphrase locks a file.',
              ),
              const SizedBox(height: 24),
              _Step(
                number: '2',
                text: 'The locked file carries everything it needs to open.',
              ),
              const SizedBox(height: 24),
              _Step(
                number: '3',
                text: 'Open it later on any device — with the passphrase.',
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: LatchSecondaryButton(
                      label: 'Skip',
                      onPressed: () => context.go('/onboarding/device-check'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: LatchPrimaryButton(
                      label: 'Next',
                      onPressed: () => context.go('/onboarding/device-check'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String text;

  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: LatchColors.ink, width: 2.5),
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: LatchColors.ink,
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ),
      ],
    );
  }
}
