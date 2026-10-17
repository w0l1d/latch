import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/saf_bridge.dart';
import '../../shared/theme/app_theme.dart';

/// The folders Android lets Latch write into, and the only way to take one
/// back.
///
/// Two things at once. It is the honest answer to "what does this app still
/// have access to" — worth showing on its own merits for an encryption app,
/// since a folder grant survives until it is revoked, not until the app is
/// closed. And it is the release valve for a table that otherwise only grows:
/// Latch takes one persisted grant per distinct source folder, and at the
/// platform ceiling Android starts dropping the *oldest* grant, which is not
/// necessarily one the user stopped caring about (issue #67).
///
/// Nothing here is cached. The list is read from Android's persisted-permission
/// table on entry and after every revoke, for the same reason
/// `existingTreeGrantFor` re-asks each batch: a remembered grant can outlive
/// the grant it names.
class SaveFoldersScreen extends StatefulWidget {
  const SaveFoldersScreen({super.key});

  @override
  State<SaveFoldersScreen> createState() => _SaveFoldersScreenState();
}

class _SaveFoldersScreenState extends State<SaveFoldersScreen> {
  SafTreeGrants _grants = SafTreeGrants.empty;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final grants = await SafBridge.listTreeGrants();
    if (!mounted) return;
    setState(() {
      _grants = grants;
      _loaded = true;
    });
  }

  Future<void> _revoke(SafTreeGrant grant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove access to this folder?'),
        // Say what does *not* happen: revoking access is easy to read as
        // deleting something, and no file is touched either way.
        content: Text(
          'Latch will lose access to "${grant.label}". Files in it are '
          'untouched — the next time Latch needs this folder, it will ask '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Revoke',
              style: TextStyle(color: LatchColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final released = await SafBridge.releaseTreeGrant(grant.uri);
    if (!mounted) return;
    if (!released) {
      // Not a lie the user can act on otherwise: the row is still there
      // because Android still holds the grant.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Android would not release this folder.')),
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Save folders'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Text(
              'Folders you have given Latch access to. Latch uses them to save '
              'locked and unlocked files, and to read a folder you choose to '
              'lock or unlock. Android does not record why a folder was '
              'allowed, so any of them may be used for either.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 20),
            if (!_loaded)
              const Center(child: CircularProgressIndicator())
            else if (_grants.grants.isEmpty)
              Text(
                'Latch has no folder access yet. It asks the first time it needs '
                'to save beside an original or to work through a folder.',
                style: text.bodySmall,
              )
            else ...[
              Text(
                _headroom(_grants),
                style: text.bodySmall?.copyWith(
                  color: _grants.nearLimit ? LatchColors.danger : null,
                  fontWeight: _grants.nearLimit ? FontWeight.w600 : null,
                ),
              ),
              if (_grants.nearLimit) ...[
                const SizedBox(height: 8),
                Text(
                  'Android drops the oldest folder when the limit is reached. '
                  'Revoke the ones you no longer use and Latch will keep the '
                  'rest.',
                  style: text.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              ..._grants.grants.map(
                (g) => _GrantTile(grant: g, onRevoke: () => _revoke(g)),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// "3 folders" until the ceiling is worth naming — an unfamiliar "3 of 512"
  /// invites the question of what 512 is, for a number nobody is near.
  static String _headroom(SafTreeGrants g) {
    final noun = g.count == 1 ? 'folder' : 'folders';
    if (!g.nearLimit || g.limit == 0) return '${g.count} $noun';
    return '${g.count} of ${g.limit} $noun this device allows';
  }
}

class _GrantTile extends StatelessWidget {
  final SafTreeGrant grant;
  final VoidCallback onRevoke;

  const _GrantTile({required this.grant, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // The basename is what identifies a folder at a glance; the full path is
    // what disambiguates two folders with the same name, so show both when
    // there is a path to split. Grants that front no path have only a label.
    final hasPath = grant.path != null && grant.path!.isNotEmpty;
    final title = hasPath ? p.basename(grant.path!) : grant.label;
    final subtitle = hasPath ? grant.path! : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_outlined, color: LatchColors.muted),
      title: Text(
        title.isEmpty ? grant.label : title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium,
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
            ),
      trailing: IconButton(
        icon: const Icon(Icons.link_off, color: LatchColors.danger),
        tooltip: 'Revoke access to this folder',
        onPressed: onRevoke,
      ),
    );
  }
}
