import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class DecryptSuccessScreen extends StatelessWidget {
  final List<String> files;

  const DecryptSuccessScreen({super.key, required this.files});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/home');
      },
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
                  files.length > 1 ? '${files.length} files restored.' : 'File restored.',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                // Flexible + ListView: a large batch scrolls instead of
                // overflowing the column.
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: files.map((f) => Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 8),
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
                              p.basename(f),
                              style: const TextStyle(fontSize: 14, color: Color(0xFF2A6F57)),
                            ),
                            Text(
                              'In ${p.dirname(f)}',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF6FAE93)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )).toList(),
                  ),
                ),
                const Spacer(),
                LatchPrimaryButton(
                  label: 'Done',
                  onPressed: () => context.go('/home'),
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
