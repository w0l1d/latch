import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptReviewScreen extends StatelessWidget {
  final List<String> files;
  final String passphrase;
  final bool deleteOriginals;
  final String? outputDir;

  const EncryptReviewScreen({
    super.key,
    required this.files,
    required this.passphrase,
    required this.deleteOriginals,
    this.outputDir,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Ready to lock'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            children: [
              _ReviewRow(label: 'Files', value: '${files.length} · ${files.join(', ')}'),
              _Divider(),
              _ReviewRow(
                label: 'Passphrase',
                value: 'Set · strong',
                valueColor: LatchColors.safe,
              ),
              _Divider(),
              _ReviewRow(
                label: 'Originals',
                value: deleteOriginals ? 'Deleted after' : 'Kept',
              ),
              _Divider(),
              _ReviewRow(
                label: 'Output',
                value: outputDir == null
                    ? '.latch beside each'
                    : 'Folder · ${p.basename(outputDir!)}',
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: LatchColors.border, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Remember this passphrase — it\'s the only way back in.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Lock ${files.length} file${files.length == 1 ? '' : 's'}',
                onPressed: () => context.push(
                  '/encrypt/progress',
                  extra: {
                    'files': files,
                    'passphrase': passphrase,
                    'deleteOriginals': deleteOriginals,
                    'outputDir': outputDir,
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _ReviewRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Flexible(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: valueColor ?? LatchColors.ink,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(color: LatchColors.border, height: 1, thickness: 1);
  }
}
