import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class LatchPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Stable test identifier, exposed to Android as a `resource-id` so UI
  /// automation matches the control rather than its copy. Copy changes with
  /// the product; a test anchor should not.
  final String? semanticsId;

  const LatchPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
    this.semanticsId,
  });

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
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
    if (semanticsId == null) return button;
    return _identified(semanticsId!, button);
  }
}

/// Wraps [child] in the semantics node that carries [id].
///
/// The `key` is not decoration. Flutter assigns a changed `identifier` to the
/// node (semantics.dart, `SemanticsNode.updateWith`) but does *not* treat that
/// change as making the node dirty (`_isDifferentFromCurrentSemanticAnnotation`
/// compares both traversal identifiers and omits this one). A node that is
/// reused across a state change therefore never gets re-sent to the engine, and
/// Android goes on reporting its **old** `resource-id` — while the Dart-side
/// tree, and so every widget test, says the new one.
///
/// That is exactly the shape of a button that changes role in place: the folder
/// screen's primary action is `encrypt_folder_pick` ("Choose a folder") until a
/// folder is scanned, then `encrypt_folder_continue` ("Set a passphrase"). Keyed
/// on the identifier, a changed id is a different element, hence a new node,
/// which the engine always reports.
Widget _identified(String id, Widget child) =>
    Semantics(key: ValueKey(id), identifier: id, child: child);

class LatchSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final String? semanticsId;

  const LatchSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticsId,
  });

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(onPressed: onPressed, child: Text(label)),
    );
    if (semanticsId == null) return button;
    return _identified(semanticsId!, button);
  }
}
