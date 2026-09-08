/// Identifies the build that produced this binary.
///
/// `package_info_plus` can only report what Gradle was handed — the semver and
/// build number — and the release tag carries a third part (its date) that
/// deliberately never reaches `pubspec.yaml`. So `v1.0.6-2026.09.08.1` and
/// `v1.0.6-2026.07.20.1` install as the same `1.0.6+1`, and nothing in an
/// installed APK says which commit it came from. These constants close that
/// gap: the workflows inject them with `--dart-define`, and Settings → About
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
  static bool get isLocal => channel == 'local' || tag.isEmpty;

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
}
