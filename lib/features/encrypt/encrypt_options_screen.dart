import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptOptionsScreen extends StatefulWidget {
  final List<String> files;
  final String passphrase;

  const EncryptOptionsScreen({super.key, required this.files, required this.passphrase});

  @override
  State<EncryptOptionsScreen> createState() => _EncryptOptionsScreenState();
}

class _EncryptOptionsScreenState extends State<EncryptOptionsScreen> {
  bool _deleteOriginals = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('After locking…'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            children: [
              _OptionCard(
                title: 'Keep the originals',
                subtitle: 'You\'ll have both the file and its locked copy.',
                selected: !_deleteOriginals,
                onTap: () => setState(() => _deleteOriginals = false),
              ),
              const SizedBox(height: 12),
              _OptionCard(
                title: 'Delete originals after',
                subtitle: 'Remove the unlocked copies once locking succeeds.',
                selected: _deleteOriginals,
                onTap: () => setState(() => _deleteOriginals = true),
              ),
              const SizedBox(height: 16),
              Container(
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
                        'Deleting is best-effort. What truly protects deleted remnants is your phone\'s built-in device encryption.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF8A5E1E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Continue',
                onPressed: () => context.push(
                  '/encrypt/review',
                  extra: {
                    'files': widget.files,
                    'passphrase': widget.passphrase,
                    'deleteOriginals': _deleteOriginals,
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

class _OptionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _OptionCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? LatchColors.ink : LatchColors.border,
            width: selected ? 2.5 : 1.5,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? LatchColors.ink : LatchColors.border,
                  width: 2,
                ),
              ),
              child: selected
                  ? const Center(
                      child: CircleAvatar(
                        radius: 5,
                        backgroundColor: LatchColors.ink,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
