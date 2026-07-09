import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class LatchPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const LatchPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor ?? LatchColors.ink,
          foregroundColor: foregroundColor ?? Colors.white,
          disabledBackgroundColor: LatchColors.border,
          disabledForegroundColor: LatchColors.subtle,
        ),
        child: Text(label),
      ),
    );
  }
}

class LatchSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const LatchSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}
