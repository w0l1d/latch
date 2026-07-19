import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptSuccessScreen extends StatelessWidget {
  /// Full paths the worker actually wrote the .latch files to.
  final List<String> files;

  const EncryptSuccessScreen({super.key, required this.files});

  /// Human description of where the outputs landed, from the real paths.
  String get _savedWhere {
    final dirs = files.map(p.dirname).toSet();
    if (dirs.isEmpty) return '';
    if (dirs.length == 1) return 'Saved in ${dirs.first}';
    return 'Saved across ${dirs.length} folders';
  }

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
                  '${files.length} file${files.length == 1 ? '' : 's'} locked.',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ...files.map((f) => _OutputFile(name: p.basename(f))),
                const SizedBox(height: 12),
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
