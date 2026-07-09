import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class DecryptSuccessScreen extends StatelessWidget {
  final String file;

  const DecryptSuccessScreen({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: LatchColors.safeLight,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: LatchColors.safeLight,
                    border: Border.all(color: LatchColors.safe, width: 3),
                  ),
                  child: const Icon(Icons.check, color: LatchColors.safe, size: 32),
                ),
                const SizedBox(height: 20),
                Text(
                  'File restored.',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: LatchColors.safeLight,
                    border: Border.all(color: LatchColors.safeBorder, width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.insert_drive_file_outlined, color: LatchColors.safe),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file,
                              style: const TextStyle(fontSize: 14, color: Color(0xFF2A6F57)),
                            ),
                            const Text(
                              'Ready to open',
                              style: TextStyle(fontSize: 12, color: Color(0xFF6FAE93)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: LatchSecondaryButton(
                        label: 'Show in files',
                        onPressed: () => context.go('/home'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: LatchPrimaryButton(
                        label: 'Open',
                        onPressed: () => context.go('/home'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
