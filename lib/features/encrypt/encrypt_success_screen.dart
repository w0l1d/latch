import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptSuccessScreen extends StatelessWidget {
  final List<String> files;

  const EncryptSuccessScreen({super.key, required this.files});

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
                  '${files.length} file${files.length == 1 ? '' : 's'} locked.',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ...files.map((f) => _OutputFile(name: f)),
                const SizedBox(height: 12),
                Text(
                  'Saved next to the originals.',
                  style: Theme.of(context).textTheme.bodySmall,
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
                        label: 'Done',
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

class _OutputFile extends StatelessWidget {
  final String name;

  const _OutputFile({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LatchColors.safeLight,
        border: Border.all(color: LatchColors.safeBorder, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file_outlined, color: LatchColors.safe),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 14, color: Color(0xFF2A6F57)),
            ),
          ),
        ],
      ),
    );
  }
}
