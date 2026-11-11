/// Identifies the build that produced this binary.
///
/// For a release, `release.yml` passes the whole tag to
/// `flutter build --build-name`, so the APK's versionName *is* the tag
/// (`v1.0.18-2026.11.10.19`) and `package_info_plus` reports it as-is. These
/// constants carry the parts the manifest has no field for: the commit SHA,
/// and the channel that separates a release install from the side-by-side dev
/// build. The workflows inject them with `--dart-define`, and Settings → About
/// shows them, so a screenshot in a bug report is enough to find the build.
///
/// **Every read must stay in a const context.** `String.fromEnvironment` only
/// sees a `--dart-define` value when it is const-evaluated; call it non-const
/// and it silently returns the default — which would show "local build" on a
/// shipped APK, the exact failure this exists to prevent. Hence `static const`
/// fields rather than getters, and `channel` is compared, never rebuilt.
class BuildInfo {
  /// The release tag that produced this build (`v1.0.6-2026.09.08.1`), or
  /// `dev.<short sha>` for a dev build. Empty in a local build.
  static const String tag = String.fromEnvironment('LATCH_BUILD_TAG');

  /// Short commit SHA the build was cut from. Empty in a local build.
  static const String sha = String.fromEnvironment('LATCH_BUILD_SHA');

  /// `release` for a tagged release, `dev` for a `dev_build.yml` APK, `local`
  /// for anything built by hand. The default is `local` on purpose: an
  /// un-injected build must under-claim, never assert a provenance it lacks.
  static const String channel = String.fromEnvironment(
    'LATCH_BUILD_CHANNEL',
    defaultValue: 'local',
  );

  /// True when this binary carries no injected provenance — a `flutter run`, a
  /// hand-built APK, or a workflow that stopped passing the defines.
  static bool get isLocal => isLocalFor(tag: tag, channel: channel);

  static bool isLocalFor({required String tag, required String channel}) =>
      channel == 'local' || tag.isEmpty;

  /// What Settings → About shows, and what a bug report needs pasted into it.
  ///
  /// Never blank and never a guess: a build with nothing injected says so
  /// outright rather than displaying an empty row that reads as a missing
  /// value. The channel is spelled out for a dev build because a device can
  /// hold a release and a dev install at once (they have different
  /// applicationIds) and the two must not be confusable in a screenshot.
  static String get label => labelFor(tag: tag, channel: channel);

  /// The label logic, split out from the injected constants so it is testable:
  /// `flutter test` can never populate a `--dart-define`, so a test of [label]
  /// alone can only ever exercise the local case.
  static String labelFor({required String tag, required String channel}) {
    if (tag.isEmpty || channel == 'local') return 'local build';
    if (channel == 'dev') return '$tag (dev build)';
    return tag;
  }

  /// What Settings → About shows on the Build row, at a glance.
  ///
  /// A release's [label] is the tag, which the Version row directly above
  /// already shows — repeating it would read as two rows for one fact. What
  /// that row can still add is the commit, so it shows the SHA (or falls back
  /// to the version when the SHA was not injected). A dev build's label carries
  /// the `(dev build)` marker its Version row lacks, so it is shown in full;
  /// a local build has nothing but "local build" to say.
  ///
  /// Split out from the injected constants for the same reason as [labelFor]:
  /// `flutter test` can never populate a `--dart-define`.
  static String rowValueFor({
    required String tag,
    required String channel,
    required String sha,
    required String version,
  }) {
    if (!isLocalFor(tag: tag, channel: channel) && channel == 'release') {
      return sha.isNotEmpty ? 'sha $sha' : version;
    }
    return labelFor(tag: tag, channel: channel);
  }
}
