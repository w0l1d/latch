import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../core/crypto_stub.dart';

class EncryptPassphraseScreen extends StatefulWidget {
  final List<String> files;
  const EncryptPassphraseScreen({super.key, required this.files});

  @override
  State<EncryptPassphraseScreen> createState() => _EncryptPassphraseScreenState();
}

class _EncryptPassphraseScreenState extends State<EncryptPassphraseScreen> {
  final _controller = TextEditingController();
  bool _obscure = true;
  PassphraseResult? _strength;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {
        _strength = _controller.text.isEmpty ? null : CryptoStub.evaluate(_controller.text);
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _strengthColor {
    switch (_strength?.strength) {
      case PassphraseStrength.weak: return LatchColors.danger;
      case PassphraseStrength.fair: return LatchColors.caution;
      case PassphraseStrength.strong: return LatchColors.safe;
      case PassphraseStrength.veryStrong: return LatchColors.safe;
      default: return LatchColors.border;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Create a passphrase'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SourceChips(),
              const SizedBox(height: 20),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Enter passphrase',
                  suffixIcon: TextButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    child: Text(_obscure ? 'show' : 'hide',
                        style: const TextStyle(color: LatchColors.subtle)),
                  ),
                ),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.5),
              ),
              const SizedBox(height: 12),
              if (_strength != null) ...[
                _StrengthBar(score: _strength!.score, color: _strengthColor),
                const SizedBox(height: 8),
                Text(
                  _strength!.label,
                  style: TextStyle(fontSize: 13, color: _strengthColor),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'A few random words beats hard-to-type symbols. Longer is stronger.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Continue',
                onPressed: _controller.text.isNotEmpty
                    ? () => context.push(
                          '/encrypt/options',
                          extra: {
                            'files': widget.files,
                            'passphrase': _controller.text,
                          },
                        )
                    : null,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceChips extends StatefulWidget {
  @override
  State<_SourceChips> createState() => _SourceChipsState();
}

class _SourceChipsState extends State<_SourceChips> {
  int _selected = 0;
  final _labels = ['Type it', 'From app', 'Password mgr'];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: List.generate(_labels.length, (i) {
        final active = i == _selected;
        return GestureDetector(
          onTap: () => setState(() => _selected = i),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: active ? LatchColors.ink : Colors.transparent,
              border: Border.all(
                color: active ? LatchColors.ink : LatchColors.border,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _labels[i],
              style: TextStyle(
                fontSize: 13,
                color: active ? Colors.white : LatchColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _StrengthBar extends StatelessWidget {
  final double score;
  final Color color;

  const _StrengthBar({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(4, (i) {
        final filled = score > i * 0.25;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
            height: 7,
            decoration: BoxDecoration(
              color: filled ? color : LatchColors.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }),
    );
  }
}
