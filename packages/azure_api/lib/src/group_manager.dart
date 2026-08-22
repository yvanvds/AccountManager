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
      'Azure: ${groups.length} groepen opgehaald voor "$schoolPrefix".',
    );
    return groups;
  }

  /// How many `mailNickname`s one [loadByMailNicknames] request asks about.
  /// Graph caps an `in (…)` list well below the URL length limit, so the lookup
  /// is chunked rather than sent as one enormous filter — the same bound
  /// `UserManager.loadByEmployeeIds` uses.
  static const int _nicknameChunk = 15;

  /// Targeted read of the groups carrying one of [mailNicknames], regardless of
  /// what their `displayName` says (#280).
  ///
  /// The group counterpart of `UserManager.loadByEmployeeIds` (#224/#231), and
  /// it exists for the same reason. [listGroups] is scoped to
  /// `startswith(displayName,'<PREFIX>')`, so a class group somebody renamed by
  /// hand — or one that was never in our namespace — is invisible to every pull
  /// we make, however firmly it holds the `<PREFIX>-<KLAS>` nickname a create
  /// would collide with. Without this read the guard in
  /// `CreateAzureClassGroup.apply` refuses the create forever and the advice it
  /// gives ("sync again") can never come true.
  ///
  /// The **nickname**, not the display name, is the key: it is what makes the
  /// address unique, it is what a create collides on, and it is the one field on
  /// such a group that is still ours. The caller passes only the nicknames it
  /// could **not** account for, so the set stays small and bounded and the
  /// PAIN-2 property of the bulk read survives.
  ///
  /// [withMembers] loads each hit's member ids the way [listGroups] does, so an
  /// adopted group can be roster-diffed on the very pass it arrives. The
  /// pre-create guard ([findByMailNickname]) turns it off: it only needs to know
  /// whether a group answers at all.
  ///
  /// Blank nicknames are dropped, duplicates collapse, and the result is
  /// de-duplicated by Azure object id.
  Future<List<AzureGroup>> loadByMailNicknames(
    Iterable<String> mailNicknames, {
    bool withMembers = true,
  }) async {
    // A set literal preserves insertion order, so the chunking (and therefore
    // the requests a test asserts on) is deterministic.
    final unique = <String>{
      for (final raw in mailNicknames)
        if (raw.trim().isNotEmpty) raw.trim(),
    }.toList();
    if (unique.isEmpty) return const <AzureGroup>[];

    final rowsById = <String, Map<String, dynamic>>{};
    for (var i = 0; i < unique.length; i += _nicknameChunk) {
      final chunk = unique.sublist(
        i,
        (i + _nicknameChunk).clamp(0, unique.length),
      );
      final literals = chunk.map((n) => "'${_escapeODataString(n)}'").join(',');
      final url = _graph.uri(
        'groups',
        query: {
          r'$select': _select,
          r'$count': 'true',
          r'$filter': 'mailNickname in ($literals)',
        },
      );
      final rows =
          await _graph.getCollection(url, headers: _advancedQueryHeaders);
      for (final row in rows) {
        rowsById[(row['id'] as String?) ?? ''] = row;
      }
    }

    final groups = <AzureGroup>[];
    for (final entry in rowsById.entries) {
      groups.add(AzureGroup.fromGraphJson(
        entry.value,
        members: withMembers ? await loadMemberIds(entry.key) : const [],
      ));
    }
    _log?.addMessage(
      core.Origin.azure,
      'Azure: ${unique.length} mailNickname(s) rechtstreeks opgezocht — '
      '${groups.length} bestaande groep(en) gevonden.',
    );
    return groups;
  }

  /// The group answering on [mailNickname], or `null` when the tenant has none.
  ///
  /// The pre-create guard for [createGroup], mirroring
  /// `UserManager.findByEmployeeId` (#224): the nickname is what makes the
  /// address unique, and Graph does **not** reject a second group that reuses a
  /// display name — it happily creates a duplicate whose address it then
  /// suffixes. Asking first is the only way a create stays idempotent across a
  /// retry or a second operator.
  ///
  /// [listGroups] cannot answer this: it is scoped to the school prefix and
  /// matches on `displayName`, so a class group somebody renamed by hand still
  /// holds the nickname a create would collide with. [loadByMailNicknames] is
  /// the pull-side answer to that same blindness (#280).
  Future<AzureGroup?> findByMailNickname(String mailNickname) async {
    final matches =
        await loadByMailNicknames([mailNickname], withMembers: false);
    return matches.isEmpty ? null : matches.first;
  }

  /// Creates a **unified** (Microsoft 365) group — the shape a class group must
  /// have to be mailed and attached to a Team (#228).
  ///
  /// Deliberately not the security group legacy created for its staff groups
  /// (`{prefix}-Personeel` and friends): `groupTypes: ["Unified"]` +
  /// `mailEnabled: true` + `securityEnabled: false` is what gives the group a
  /// mailbox at `<mailNickname>@<tenant mail domain>`.
  ///
  /// The created group is returned with **no members**; membership is a separate
  /// write ([addMembers]), so a create that lands but whose membership pass
  /// fails leaves a correct, empty group rather than a half-populated one.
  Future<AzureGroup> createGroup({
    required String displayName,
    required String mailNickname,
    String description = '',
    String visibility = 'Private',
  }) async {
    final body = <String, dynamic>{
      'displayName': displayName,
      'mailNickname': mailNickname,
      if (description.trim().isNotEmpty) 'description': description,
      'groupTypes': const ['Unified'],
      'mailEnabled': true,
      'securityEnabled': false,
      'visibility': visibility,
    };
    final json = await _graph.postJson(_graph.uri('groups'), body);
    _log?.addMessage(
      core.Origin.azure,
      'Azure: Microsoft 365-groep $displayName ($mailNickname) aangemaakt.',
    );
    // The create response echoes the new resource; fall back to the request
    // values for anything Graph left out of its echo (as `createUser` does).
    return AzureGroup(
      id: (json['id'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? displayName,
      securityEnabled: (json['securityEnabled'] as bool?) ?? false,
      mail: json['mail'] as String?,
      mailNickname: (json['mailNickname'] as String?) ?? mailNickname,
    );
  }

  /// Deletes a group outright (#271) — the write behind
  /// `DeleteAzureClassGroup`, for the Office 365 group of a class that no
  /// longer runs anywhere.
  ///
  /// Graph deletes the group *and* everything hanging off it: the mailbox and
  /// its history, the Team, the SharePoint site and the files on it. There is
  /// no undo beyond the tenant's own 30-day soft-delete window, which is why
  /// the action that calls this is never the default of a bulk apply.
  Future<void> deleteGroup(String groupId) async {
    await _graph.delete(_graph.uri('groups/${Uri.encodeComponent(groupId)}'));
    _log?.addMessage(
      core.Origin.azure,
      'Azure: groep $groupId verwijderd.',
    );
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
      'Azure: $userId toegevoegd aan groep $groupId.',
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
      'Azure: $userId verwijderd uit groep $groupId.',
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
      'Azure: ${userIds.length} leden in batch toegevoegd aan groep $groupId.',
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
      'Azure: ${userIds.length} leden in batch verwijderd uit groep $groupId.',
    );
    return results;
  }

  static String _directoryObjectRef(String userId) =>
      'https://graph.microsoft.com/v1.0/directoryObjects/$userId';

  static String _escapeODataString(String value) => value.replaceAll("'", "''");
}
