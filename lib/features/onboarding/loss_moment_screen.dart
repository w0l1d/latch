import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';

class LossMomentScreen extends StatefulWidget {
  const LossMomentScreen({super.key});

  @override
  State<LossMomentScreen> createState() => _LossMomentScreenState();
}

class _LossMomentScreenState extends State<LossMomentScreen> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LatchColors.dangerLight,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: LatchColors.danger, width: 3),
                ),
                child: const Center(
                  child: Text(
                    '!',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                      color: LatchColors.danger,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'There is no reset.',
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  color: const Color(0xFFA8311F),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'If you forget your passphrase, your files stay locked — permanently. No one can recover them. That\'s the point.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF7A3128),
                ),
              ),
              const SizedBox(height: 28),
              MergeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _acknowledged,
                      onChanged: (v) => setState(() => _acknowledged = v ?? false),
                      side: const BorderSide(color: LatchColors.danger, width: 2),
                      fillColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) return LatchColors.danger;
                        return Colors.transparent;
                      }),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          'I understand there\'s no recovery.',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: const Color(0xFF7A3128),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _acknowledged ? () => context.go('/onboarding/ready') : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LatchColors.danger,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFF6DDD8),
                    disabledForegroundColor: const Color(0xFFB8786E),
                  ),
                  child: const Text('Continue'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
