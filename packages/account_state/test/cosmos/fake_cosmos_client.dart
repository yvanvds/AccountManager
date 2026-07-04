import 'package:account_state/account_state.dart';

/// An in-memory [CosmosClient] that models the container semantics the adapters
/// rely on: point read/upsert/delete by id, atomic create with a `/naturalKey`
/// **unique-key** rejection (the `409` the resolver converges on), and the one
/// `ARRAY_CONTAINS(@keys, c.naturalKey)` query shape it issues.
///
/// Because a call has no `await` between its check and its mutation, each
/// operation runs to completion atomically on Dart's event loop — the same
/// all-or-nothing a single Cosmos request gives — so two "operators" sharing one
/// instance exercise a realistic race. Instances may be shared to simulate the
/// one centralized account seen by every operator.
class FakeCosmosClient implements CosmosClient {
  /// container → (id → document).
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};

  int queryCount = 0;
  int createCount = 0;

  Map<String, Map<String, dynamic>> _container(String name) =>
      _store.putIfAbsent(name, () => {});

  /// Seeds an identity document directly (bypassing create), as if another
  /// operator had already minted it.
  void seedIdentity(String naturalKey, String personId) {
    _container(identityContainer)[personId] = {
      'id': personId,
      'pk': identityPartitionKeyValue,
      'naturalKey': naturalKey,
      'personId': personId,
    };
  }

  @override
  Future<Map<String, dynamic>?> readDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    final doc = _container(container)[id];
    return doc == null ? null : Map<String, dynamic>.from(doc);
  }

  @override
  Future<bool> createDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async {
    createCount++;
    final docs = _container(container);
    final naturalKey = document['naturalKey'];
    if (naturalKey != null &&
        docs.values.any((d) => d['naturalKey'] == naturalKey)) {
      return false; // unique-key conflict on /naturalKey
    }
    final id = document['id'] as String;
    if (docs.containsKey(id)) return false; // id conflict
    docs[id] = Map<String, dynamic>.from(document);
    return true;
  }

  @override
  Future<void> upsertDocument({
    required String container,
    required Map<String, dynamic> document,
    required String partitionKey,
  }) async {
    _container(container)[document['id'] as String] =
        Map<String, dynamic>.from(document);
  }

  @override
  Future<void> deleteDocument({
    required String container,
    required String id,
    required String partitionKey,
  }) async {
    _container(container).remove(id);
  }

  @override
  Future<List<Map<String, dynamic>>> queryDocuments({
    required String container,
    required String query,
    Map<String, Object?> parameters = const {},
    String? partitionKey,
  }) async {
    queryCount++;
    // The adapters issue exactly one query shape: keys IN @keys. Interpret it
    // by the bound parameter rather than parsing SQL.
    final keys = (parameters['@keys'] as List?)?.cast<Object?>() ?? const [];
    return [
      for (final doc in _container(container).values)
        if (keys.contains(doc['naturalKey'])) Map<String, dynamic>.from(doc),
    ];
  }
}
