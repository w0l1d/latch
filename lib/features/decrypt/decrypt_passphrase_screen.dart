import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class DecryptPassphraseScreen extends StatefulWidget {
  final List<String> files;
  const DecryptPassphraseScreen({super.key, required this.files});

  @override
  State<DecryptPassphraseScreen> createState() => _DecryptPassphraseScreenState();
}

class _DecryptPassphraseScreenState extends State<DecryptPassphraseScreen> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    context.push(
      '/decrypt/progress',
      extra: {
        'files': widget.files,
        'passphrase': _controller.text,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: Text(widget.files.length > 1 ? 'Open ${widget.files.length} files' : 'Open this file'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: LatchColors.border, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, color: LatchColors.ink),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.files.length == 1
                            ? widget.files.first
                            : '${widget.files.length} files selected',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: LatchColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Enter the passphrase used to lock it.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Passphrase',
                  suffixIcon: TextButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    child: Text(_obscure ? 'show' : 'hide',
                        style: const TextStyle(color: LatchColors.subtle)),
                  ),
                ),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.5),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: LatchColors.border, width: 1.5, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        border: Border.all(color: LatchColors.muted, width: 1.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.fingerprint, size: 14, color: LatchColors.muted),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Use quick unlock instead',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Unlock',
                onPressed: _controller.text.isNotEmpty ? _submit : null,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
