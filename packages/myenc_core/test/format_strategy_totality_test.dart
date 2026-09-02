// The structural fail-closed guarantee behind specs/003: the dispatch
// table's key set and FormatVersionRegistry.all's value set must agree in
// both directions. A registry entry that gained no strategy — or a
// strategy for a version the registry doesn't know — fails HERE, at test
// time, rather than surfacing as a runtime crash on a real user's file.
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

void main() {
  test('every registered format version has exactly one dispatch strategy', () {
    final registryVersions = FormatVersionRegistry.all.keys.toSet();
    final dispatchVersions = formatVersionStrategies.keys.toSet();

    expect(
      dispatchVersions,
      equals(registryVersions),
      reason:
          'dispatch table and FormatVersionRegistry.all must cover exactly '
          'the same version numbers',
    );
  });
}
