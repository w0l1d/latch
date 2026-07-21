import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/output_plan.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptSuccessScreen extends StatelessWidget {
  /// Where the worker actually wrote each locked file (after relocation).
  final List<RelocatedOutput> outputs;

  const EncryptSuccessScreen({super.key, required this.outputs});

  /// Human description of where the outputs landed, from the real paths.
  String get _savedWhere {
    final dirs = outputs.map((o) => p.dirname(o.path)).toSet();
    if (dirs.isEmpty) return '';
    if (dirs.length == 1) return 'Saved in ${dirs.first}';
    return 'Saved across ${dirs.length} folders';
  }

  @override
  Widget build(BuildContext context) {
    final fallbackCount = outputs.where((o) => o.fellBackToDownloads).length;
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
                  child: const Icon(
                    Icons.check,
                    color: LatchColors.safe,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '${outputs.length} file${outputs.length == 1 ? '' : 's'} locked.',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                // Flexible + ListView: a large batch scrolls instead of
                // overflowing the column.
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: outputs
                        .map(
                          (o) => _OutputFile(
                            name: p.basename(o.path),
                            fellBack: o.fellBackToDownloads,
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 12),
                if (fallbackCount > 0)
                  _FallbackBanner(count: fallbackCount)
                else
                  Text(
                    _savedWhere,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
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

class _FallbackBanner extends StatelessWidget {
  final int count;
  const _FallbackBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LatchColors.cautionLight,
        border: Border.all(color: LatchColors.caution, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: LatchColors.caution, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count file${count == 1 ? '' : 's'} couldn\'t be saved to the '
              'original folder and ${count == 1 ? 'was' : 'were'} saved to '
              'Downloads instead.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF8A5E1E)),
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputFile extends StatelessWidget {
  final String name;
  final bool fellBack;

  const _OutputFile({required this.name, this.fellBack = false});

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
              fellBack ? '$name  (in Downloads)' : name,
              style: const TextStyle(fontSize: 14, color: Color(0xFF2A6F57)),
            ),
          ),
        ],
      ),
    );
  }
}
