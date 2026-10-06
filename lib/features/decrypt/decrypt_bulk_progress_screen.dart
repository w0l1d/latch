import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/app_crypto.dart';
import '../../core/bulk_plan.dart';
import '../../core/output_plan.dart';
import '../../core/save_folder_prompt.dart';
import '../../core/verified_delete.dart';
import '../encrypt/encrypt_bulk_progress_screen.dart' show BulkRunSummary;
import '../../shared/error_messages.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../shared/widgets/latch_button.dart';

class DecryptBulkProgressScreen extends StatefulWidget {
  final BulkInventory inventory;
  final String passphrase;
  final bool deleteSources;

  /// Where the review step sent the output. Null means beside the originals.
  final BulkDestination? destination;

  const DecryptBulkProgressScreen({
    super.key,
    required this.inventory,
    required this.passphrase,
    required this.deleteSources,
    this.destination,
  });

  @override
  State<DecryptBulkProgressScreen> createState() => _State();
}

class _State extends State<DecryptBulkProgressScreen> {
  double _progress = 0;
  StreamSubscription<double>? _sub;
  bool _cancelled = false;
  bool _finished = false;
  final _outcomes = <String, BulkFileOutcome>{};
  OutputPlan? _plan;

  late final BulkDestination _dest =
      widget.destination ??
      const BulkDestination(placement: BulkPlacement.besideOriginals);
  late final List<BulkItem> _items = BulkPlan.applyPlacement(
    widget.inventory.items,
    _dest.placement,
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    Uint8List? deviceKey;
    Uint8List? recipientPk;
    Uint8List? recipientSk;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('device_bound_recovery') ?? false) {
        deviceKey = await AppCrypto.deviceKeyService?.getOrCreateKey();
      }
      final recipientSvc = AppCrypto.recipientKeys;
      if (recipientSvc != null && await recipientSvc.hasKeyPair()) {
        final kp = await recipientSvc.getOrCreateKeyPair();
        recipientPk = kp.publicKey;
        recipientSk = kp.secretKey;
      }
      _plan = await OutputPlanner.planBulk(
        root: widget.inventory.root,
        items: _items,
        allowDownloadsFallback: false,
        explicitDir: _dest.plannerDir,
        explicitTreeUri: _dest.plannerTreeUri,
        requestGrant: (folder, sourcePath) async {
          if (!mounted || _cancelled) {
            return const SaveFolderDecision.cancelled();
          }
          return promptSaveFolder(context, folder, sourcePath: sourcePath);
        },
      );
    } catch (e) {
      if (mounted && !_cancelled) _fail(userMessageForError(e));
      return;
    }
    final plan = _plan!;
    if (plan.cancelled) {
      _cancelled = true;
      if (mounted) context.pop();
      return;
    }
    if (!mounted) return;
    _sub =
        AppCrypto.decryptFiles(
          [for (final i in _items) i.sourcePath],
          widget.passphrase,
          deleteOriginals: widget.deleteSources,
          verifyDelete: widget.deleteSources,
          outputDir: plan.outputDir,
          stagingDir: plan.stagingDir,
          outRelPaths: [for (final i in _items) i.outRelPath],
          deviceKey: deviceKey,
          recipientPublicKey: recipientPk,
          recipientSecretKey: recipientSk,
          onFileResult: (path, ok, error, outPath) {
            _outcomes[path] = BulkFileOutcome(
              path: path,
              ok: ok,
              errorMessage: error,
              outPath: outPath,
            );
          },
          onFileVerified: (path, verified, removed) {
            final o = _outcomes[path];
            if (o == null) return;
            _outcomes[path] = BulkFileOutcome(
              path: o.path,
              ok: o.ok,
              errorMessage: o.errorMessage,
              outPath: o.outPath,
              verified: verified,
              sourceRemoved: removed,
            );
          },
        ).listen(
          (prog) {
            if (!mounted || _cancelled) return;
            setState(() => _progress = prog);
            if (_outcomes.length >= _items.length) _finish();
          },
          onError: (Object e) {
            if (mounted && !_cancelled) _fail(userMessageForError(e));
          },
          onDone: () {
            if (!mounted || _cancelled) return;
            if (_outcomes.length >= _items.length) {
              _finish();
            } else {
              _fail(
                'Unlocking stopped unexpectedly. '
                '${_outcomes.length} of ${_items.length} files were processed.',
              );
            }
          },
        );
  }

  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    final results = [
      for (final o in _outcomes.values)
        BatchResult(
          path: o.path,
          ok: o.ok,
          errorMessage: o.errorMessage,
          outPath: o.outPath,
        ),
    ];
    final nameOf = {
      for (final i in _items) i.sourcePath: p.posix.basename(i.outRelPath),
    };
    List<RelocatedOutput> outputs;
    try {
      outputs = await relocateStagedOutputs(
        results,
        _plan ?? const OutputPlan(),
        allowDownloadsFallback: false,
        displayNameFor: (s) => nameOf[s] ?? '${p.basename(s)}.decrypted',
      );
    } catch (e) {
      if (mounted) _fail(userMessageForError(e));
      return;
    }
    if (widget.deleteSources) {
      final removed = await removeVerifiedSources(
        verifiedPaths: [
          for (final o in _outcomes.values)
            if (o.ok && o.verified && !o.sourceRemoved) o.path,
        ],
        relocated: outputs,
      );
      for (final path in removed) {
        final o = _outcomes[path]!;
        _outcomes[path] = BulkFileOutcome(
          path: o.path,
          ok: o.ok,
          errorMessage: o.errorMessage,
          outPath: o.outPath,
          verified: true,
          sourceRemoved: true,
        );
      }
    }
    if (!mounted) return;
    context.pushReplacement(
      '/decrypt/bulk-result',
      extra: BulkRunSummary(
        root: widget.inventory.root,
        total: _items.length,
        outcomes: _outcomes.values.toList(),
        outputs: outputs,
        deleteSources: widget.deleteSources,
        skipped: widget.inventory.skipped.length,
        destination: _dest,
      ),
    );
  }

  void _fail(String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: 'Unlocking failed',
      message: message,
      buttonLabel: 'Go back',
      onPressed: () {
        Navigator.of(context).pop();
        if (mounted) context.pop();
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _items.length;
    final done = _outcomes.length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _cancelled = true;
          _sub?.cancel();
          context.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Column(
              children: [
                const Spacer(),
                Text(
                  'Unlocking $total files…',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  semanticsLabel: 'Unlocking files',
                  semanticsValue: '${(_progress * 100).round()} percent',
                  value: _progress,
                  backgroundColor: LatchColors.border,
                  color: LatchColors.ink,
                  minHeight: 10,
                ),
                const SizedBox(height: 12),
                Text(
                  '$done of $total',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                LatchSecondaryButton(
                  label: 'Cancel',
                  onPressed: () {
                    _cancelled = true;
                    _sub?.cancel();
                    context.pop();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
