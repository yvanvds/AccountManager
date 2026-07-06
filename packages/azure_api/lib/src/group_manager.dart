import 'package:account_core/account_core.dart' as core;

import 'graph/graph_batch.dart';
import 'graph/graph_client.dart';
import 'models/azure_group.dart';

/// Reads and writes Azure AD groups and their memberships via Microsoft Graph.
///
/// Mirrors the legacy `GroupManager.cs` / `Group.cs` surface: lists the
/// prefixed groups, loads their members, and adds/removes members. Multi-write
/// membership changes are coalesced with `$batch`. Legacy reference
/// (read-only): `legacy-wpf/AccountApi/Azure/GroupManager.cs`,
/// `legacy-wpf/AccountApi/Azure/Group.cs`.
class GroupManager {
  final GraphClient _graph;
  final core.ILog? _log;
  final GraphBatch _batch;

  GroupManager(this._graph, {core.ILog? log})
      : _log = log,
        _batch = GraphBatch(_graph);

  static final String _select = AzureGroup.graphSelectFields.join(',');

  /// Emit a progress log line for every this-many groups pulled (issue #177).
  static const int _progressEvery = 20;

  static const Map<String, String> _advancedQueryHeaders = {
    'ConsistencyLevel': 'eventual',
  };

  /// Lists groups whose display name starts with [schoolPrefix] and loads each
  /// group's member ids. Mirrors legacy `LoadFromAzure` +
  /// `Group.LoadMembers`.
  Future<List<AzureGroup>> listGroups(String schoolPrefix) async {
    final url = _graph.uri(
      'groups',
      query: {
        r'$select': _select,
        r'$count': 'true',
        r'$filter':
            "startswith(displayName,'${_escapeODataString(schoolPrefix)}')",
      },
    );
    final rows =
        await _graph.getCollection(url, headers: _advancedQueryHeaders);
    final groups = <AzureGroup>[];
    for (final row in rows) {
      final id = (row['id'] as String?) ?? '';
      final members = await loadMemberIds(id);
      groups.add(AzureGroup.fromGraphJson(row, members: members));
      if (groups.length % _progressEvery == 0) {
        _log?.addMessage(
          core.Origin.azure,
          'Azure: ${groups.length} groepen opgehaald…',
        );
      }
    }
    _log?.addMessage(
      core.Origin.azure,
      'Azure: loaded ${groups.length} groups for "$schoolPrefix".',
    );
    return groups;
  }

  /// Returns the object ids of a group's members, following pagination.
  Future<List<String>> loadMemberIds(String groupId) async {
    final url = _graph.uri(
      'groups/${Uri.encodeComponent(groupId)}/members',
      query: {r'$select': 'id'},
    );
    final rows = await _graph.getCollection(url);
    return rows.map((m) => m['id'] as String).toList();
  }

  /// Adds one user to a group. Mirrors legacy `Group.AddMember`.
  Future<void> addMember(String groupId, String userId) async {
    await _graph.postJson(
      _graph.uri('groups/${Uri.encodeComponent(groupId)}/members/\$ref'),
      {'@odata.id': _directoryObjectRef(userId)},
    );
    _log?.addMessage(
      core.Origin.azure,
      'Azure: added $userId to group $groupId.',
    );
  }

  /// Removes one user from a group. Mirrors legacy `Group.RemoveMember`.
  Future<void> removeMember(String groupId, String userId) async {
    await _graph.delete(
      _graph.uri(
        'groups/${Uri.encodeComponent(groupId)}/members/'
        '${Uri.encodeComponent(userId)}/\$ref',
      ),
    );
    _log?.addMessage(
      core.Origin.azure,
      'Azure: removed $userId from group $groupId.',
    );
  }

  /// Adds many users to one group in as few round-trips as possible, via
  /// `$batch`. Returns the per-user results so the caller can report partial
  /// failures.
  Future<List<BatchResponse>> addMembers(
    String groupId,
    List<String> userIds,
  ) async {
    if (userIds.isEmpty) return const [];
    final requests = [
      for (var i = 0; i < userIds.length; i++)
        BatchRequest(
          id: '$i',
          method: 'POST',
          url: '/groups/$groupId/members/\$ref',
          headers: const {'Content-Type': 'application/json'},
          body: {'@odata.id': _directoryObjectRef(userIds[i])},
        ),
    ];
    final results = await _batch.execute(requests);
    _log?.addMessage(
      core.Origin.azure,
      'Azure: batch-added ${userIds.length} members to group $groupId.',
    );
    return results;
  }

  /// Removes many users from one group via `$batch`.
  Future<List<BatchResponse>> removeMembers(
    String groupId,
    List<String> userIds,
  ) async {
    if (userIds.isEmpty) return const [];
    final requests = [
      for (var i = 0; i < userIds.length; i++)
        BatchRequest(
          id: '$i',
          method: 'DELETE',
          url: '/groups/$groupId/members/${userIds[i]}/\$ref',
        ),
    ];
    final results = await _batch.execute(requests);
    _log?.addMessage(
      core.Origin.azure,
      'Azure: batch-removed ${userIds.length} members from group $groupId.',
    );
    return results;
  }

  static String _directoryObjectRef(String userId) =>
      'https://graph.microsoft.com/v1.0/directoryObjects/$userId';

  static String _escapeODataString(String value) => value.replaceAll("'", "''");
}
