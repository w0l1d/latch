import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum LatchAlertTone { danger, caution }

/// A themed alert dialog used for crypto error and partial-success surfaces.
/// Extracted so the encrypt/decrypt flows share one calm, consistent look
/// and so the surface can be widget-tested in isolation.
class LatchAlert extends StatelessWidget {
  final LatchAlertTone tone;
  final IconData icon;
  final String title;
  final String message;
  final String buttonLabel;
  final VoidCallback onPressed;

  const LatchAlert({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    required this.message,
    required this.buttonLabel,
    required this.onPressed,
  });

  bool get _danger => tone == LatchAlertTone.danger;

  @override
  Widget build(BuildContext context) {
    final accent = _danger ? LatchColors.danger : LatchColors.caution;
    final bg = _danger ? LatchColors.dangerLight : LatchColors.cautionLight;
    final bodyColor = _danger
        ? const Color(0xFF7A3128)
        : const Color(0xFF5C3D1A);

    return AlertDialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: accent, width: 2),
      ),
      icon: Icon(icon, color: accent, size: 32),
      title: Text(
        title,
        style: TextStyle(
          color: _danger ? LatchColors.danger : LatchColors.ink,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Text(message, style: TextStyle(color: bodyColor)),
      actions: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onPressed,
            style: _danger
                ? ElevatedButton.styleFrom(
                    backgroundColor: LatchColors.danger,
                    foregroundColor: Colors.white,
                  )
                : null,
            child: Text(buttonLabel),
          ),
        ),
      ],
    );
  }
}

/// Shows a [LatchAlert] as a modal dialog.
Future<void> showLatchAlert(
  BuildContext context, {
  required LatchAlertTone tone,
  required IconData icon,
  required String title,
  required String message,
  required String buttonLabel,
  required VoidCallback onPressed,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => LatchAlert(
      tone: tone,
      icon: icon,
      title: title,
      message: message,
      buttonLabel: buttonLabel,
      onPressed: onPressed,
    ),
  );
}
