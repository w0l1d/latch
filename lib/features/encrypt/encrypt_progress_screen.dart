import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../shared/error_messages.dart';
import '../../core/app_crypto.dart';
import '../../core/output_plan.dart';
import '../../core/save_folder_prompt.dart';
import '../../core/saf_bridge.dart';

class EncryptProgressScreen extends StatefulWidget {
  final List<String> files;
  final String passphrase;
  final bool deleteOriginals;
  final String? outputDir;
  final String? explicitTreeUri;
  final String? keyIdHex;

  const EncryptProgressScreen({
    super.key,
    required this.files,
    required this.passphrase,
    required this.deleteOriginals,
    this.outputDir,
    this.explicitTreeUri,
    this.keyIdHex,
  });

  @override
  State<EncryptProgressScreen> createState() => _EncryptProgressScreenState();
}

class _EncryptProgressScreenState extends State<EncryptProgressScreen> {
  double _progress = 0;
  StreamSubscription<double>? _sub;
  bool _cancelled = false;
  final _results = <BatchResult>[];
  int _doneCount = 0;
  bool _reported = false;
  OutputPlan? _plan;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    // An empty batch would complete instantly with no events, leaving the
    // spinner running forever — fail fast and visibly instead.
    if (widget.files.isEmpty) {
      _reported = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showError('Nothing to lock', 'No files were selected.');
      });
      return;
    }
    _loadAndRun();
  }

  Future<void> _loadAndRun() async {
    Uint8List? deviceKey;
    OutputPlan plan;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('device_bound_recovery') ?? false) {
        deviceKey = await AppCrypto.deviceKeyService?.getOrCreateKey();
      }
      // Decide where locked files land (Android: stage in cache, then relocate
      // into the granted source folder afterwards). Prompts for a folder grant
      // per distinct source folder unless the user picked one explicitly.
      plan = await OutputPlanner.plan(
        widget.files,
        explicitDir: widget.outputDir,
        explicitTreeUri: widget.explicitTreeUri,
        requestGrant: (folder, sourcePath) async {
          if (!mounted || _cancelled) {
            return const SaveFolderDecision.cancelled();
          }
          return promptSaveFolder(context, folder, sourcePath: sourcePath);
        },
      );
      _plan = plan;
    } catch (e) {
      // A pre-batch platform failure (secure storage, prefs) must surface —
      // falling out of this method silently would leave the spinner forever.
      if (!mounted || _cancelled) return;
      _showFatalError(e);
      return;
    }
    // The user backed out of the save-folder prompt without naming a
    // destination. Nothing has been encrypted — planning runs before the worker
    // — so leaving is enough; go back the way the Cancel button does.
    if (plan.cancelled) {
      _cancelled = true;
      if (mounted) context.pop();
      return;
    }
    if (!mounted) return;
    _sub =
        AppCrypto.encryptFiles(
          widget.files,
          widget.passphrase,
          deleteOriginals: widget.deleteOriginals,
          outputDir: plan.outputDir,
          keyIdHex: widget.keyIdHex,
          deviceKey: deviceKey,
          onFileResult: (path, ok, error, outPath) {
            _results.add(
              BatchResult(
                path: path,
                ok: ok,
                errorMessage: error,
                outPath: outPath,
              ),
            );
            _doneCount++;
          },
        ).listen(
          (prog) {
            if (!mounted || _cancelled) return;
            setState(() => _progress = prog);
            if (_doneCount >= widget.files.length && !_reported) {
              _reported = true;
              _onDone();
            }
          },
          onError: (Object e) {
            if (!mounted || _cancelled) return;
            _showFatalError(e);
          },
          onDone: () {
            if (!mounted || _cancelled || _reported) return;
            _reported = true;
            if (_doneCount >= widget.files.length) {
              // Normal completion where the terminal progress event was missed
              // (defensive — the worker normally reports 1.0 after the last file).
              _onDone();
            } else {
              // The worker stream ended without reporting every file. Without
              // this the spinner runs forever with Cancel as the only way out.
              _showError(
                'Encryption stopped unexpectedly',
                'Only $_doneCount of ${widget.files.length} files were processed.',
              );
            }
          },
        );
  }

  Future<void> _onDone() async {
    final ok = _results.where((r) => r.ok).length;
    final bad = _results.where((r) => !r.ok).length;
    if (ok > 0) {
      final List<RelocatedOutput> outputs;
      try {
        // Android: move each staged file into its granted source folder (or
        // Downloads). Off-Android this just returns the paths the worker wrote.
        outputs = await relocateStagedOutputs(
          _results,
          _plan ?? const OutputPlan(),
          displayNameFor: (s) => '${p.basename(s)}.latch',
        );
      } catch (e) {
        if (!mounted) return;
        _showError('Encryption failed', userMessageForError(e));
        return;
      }
      // Delete originals only after the locked copies are safely in place.
      await _deleteRealOriginals();
      if (!mounted) return;
      if (bad > 0) {
        _showPartialSuccess(ok, bad, outputs);
        return;
      }
      context.pushReplacement('/encrypt/success', extra: outputs);
    } else {
      // All failed — show the first error.
      final first = _results.firstWhere((r) => !r.ok);
      _showError('Encryption failed', first.errorMessage ?? 'Unknown error');
    }
  }

  /// "Delete originals after": the worker only removed the picker's cache
  /// copies — delete the REAL documents behind them too (Android SAF).
  /// Failures are surfaced, not silent: the user chose deletion for a reason.
  Future<void> _deleteRealOriginals() async {
    if (!widget.deleteOriginals) return;
    var failed = 0;
    for (final r in _results.where((r) => r.ok)) {
      if (!SafBridge.canWriteBack(r.path)) continue;
      try {
        await SafBridge.deleteDocument(r.path);
      } catch (_) {
        failed++;
      }
    }
    if (failed > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$failed original file${failed == 1 ? '' : 's'} could not be deleted — remove ${failed == 1 ? 'it' : 'them'} manually.',
          ),
        ),
      );
    }
  }

  /// Wraps an alert button callback so it dismisses the alert and *then*
  /// navigates — at most once. Two unguarded pops in a row are a trap: a rapid
  /// double-tap (or an alert already gone) makes the first pop remove this
  /// screen's route and the second travel one level too far past the intended
  /// destination. So: run once, only pop while the alert really is above us,
  /// and re-check the context before handing over to [next].
  VoidCallback _dismissAlertThen(VoidCallback next) {
    var ran = false;
    return () {
      if (ran) return;
      ran = true;
      final nav = Navigator.of(context);
      if (ModalRoute.of(context)?.isCurrent == false && nav.canPop()) {
        nav.pop();
      }
      if (!context.mounted) return;
      next();
    };
  }

  void _showPartialSuccess(int ok, int bad, List<RelocatedOutput> outputs) {
    final listed = _results
        .where((r) => !r.ok)
        .take(3)
        .map((r) {
          return '${p.basename(r.path)}: ${r.errorMessage ?? "error"}';
        })
        .join('\n');
    final more = bad > 3 ? '\n… and ${bad - 3} more' : '';
    showLatchAlert(
      context,
      tone: LatchAlertTone.caution,
      icon: Icons.check_circle_outline,
      title: '$ok file${ok > 1 ? "s" : ""} locked, $bad failed',
      message: '$listed$more',
      buttonLabel: 'Continue',
      onPressed: _dismissAlertThen(() {
        context.pushReplacement('/encrypt/success', extra: outputs);
      }),
    );
  }

  void _showFatalError(Object e) {
    _showError('Encryption failed', userMessageForError(e));
  }

  void _showError(String title, String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: title,
      message: message,
      buttonLabel: 'Go back',
      onPressed: _dismissAlertThen(() {
        context.pop();
      }),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileCount = widget.files.length;
    final currentIndex = _doneCount.clamp(0, fileCount);
    final currentName = widget.files.isNotEmpty
        ? p.basename(widget.files[currentIndex.clamp(0, fileCount - 1)])
        : '';
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
                SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    value: _progress < 1.0 ? _progress : null,
                    strokeWidth: 4,
                    backgroundColor: LatchColors.border,
                    color: LatchColors.ink,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  fileCount > 1
                      ? 'Locking $fileCount files…'
                      : 'Locking your file…',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: LatchColors.border,
                    color: LatchColors.ink,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  fileCount > 1
                      ? '${(_doneCount + 1).clamp(1, fileCount)} of $fileCount · $currentName'
                      : currentName,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
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
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
