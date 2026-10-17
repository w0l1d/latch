import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/bulk_destination_section.dart';
import '../../shared/widgets/latch_button.dart';
import 'encrypt_bulk_progress_screen.dart';

class EncryptBulkResultScreen extends StatelessWidget {
  final BulkRunSummary summary;
  const EncryptBulkResultScreen({super.key, required this.summary});

  String _where() {
    final first = summary.outputs.isEmpty ? null : summary.outputs.first.path;
    if (first == null) return '';
    return bulkSavedWhere(
      destination: summary.destination,
      firstOut: first,
      fellBackToDownloads: summary.fellBackToDownloads,
      sourceNoun: 'originals',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = summary;
    final allOk = s.failedCount == 0;
    final failures = s.outcomes.where((o) => !o.ok).toList();
    final removed = s.outcomes.where((o) => o.sourceRemoved).length;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                allOk
                    ? '${s.okCount} file${s.okCount == 1 ? '' : 's'} locked'
                    : '${s.okCount} locked, ${s.failedCount} failed',
                style: t.displayMedium,
              ),
              const SizedBox(height: 8),
              if (!allOk)
                Text(
                  'Not everything was locked. The files below were left as '
                  'they were.',
                  style: t.bodyMedium?.copyWith(color: LatchColors.danger),
                ),
              if (s.okCount > 0) Text(_where(), style: t.bodyMedium),
              if (s.skipped > 0)
                Text(
                  '${s.skipped} skipped before locking.',
                  style: t.bodySmall,
                ),
              if (s.deleteSources)
                Text(
                  '$removed original${removed == 1 ? '' : 's'} removed after '
                  'verification. Empty folders were left in place.',
                  style: t.bodySmall,
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    for (final f in failures)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${p.relative(f.path, from: s.root)}: '
                          '${f.errorMessage ?? 'error'}',
                          style: t.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              LatchPrimaryButton(
                label: 'Done',
                onPressed: () => context.go('/home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
