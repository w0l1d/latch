import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/output_plan.dart';
import '../../core/saf_bridge.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class DecryptSuccessScreen extends StatelessWidget {
  /// Where each unlocked file actually landed (after relocation).
  final List<RelocatedOutput> outputs;

  const DecryptSuccessScreen({super.key, required this.outputs});

  /// Opens the folder the first output landed in, using its exact SAF grant
  /// when available. Shows a notice if no app can browse it.
  Future<void> _openFolder(BuildContext context) async {
    if (outputs.isEmpty) return;
    final target = outputs.first;
    final ok = await SafBridge.openFolder(
      treeUri: target.treeUri,
      path: target.treeUri == null ? p.dirname(target.path) : null,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app available to open the folder.')),
      );
    }
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
                  outputs.length > 1
                      ? '${outputs.length} files restored.'
                      : 'File restored.',
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
                          (o) => Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: LatchColors.safeLight,
                              border: Border.all(
                                color: LatchColors.safeBorder,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.insert_drive_file_outlined,
                                  color: LatchColors.safe,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.basename(o.path),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF2A6F57),
                                        ),
                                      ),
                                      Text(
                                        'In ${p.dirname(o.path)}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF6FAE93),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                if (fallbackCount > 0) ...[
                  const SizedBox(height: 12),
                  _FallbackBanner(count: fallbackCount),
                ],
                const Spacer(),
                if (Platform.isAndroid && outputs.isNotEmpty) ...[
                  LatchSecondaryButton(
                    label: 'Open folder',
                    onPressed: () => _openFolder(context),
                  ),
                  const SizedBox(height: 12),
                ],
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
              '$count file${count == 1 ? '' : 's'} '
              '${count == 1 ? 'was' : 'were'} saved to your Downloads folder '
              'instead of the original folder.',
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
