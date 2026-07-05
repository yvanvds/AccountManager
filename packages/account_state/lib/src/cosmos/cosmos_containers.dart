import 'cosmos_client.dart';
import 'cosmos_config.dart';

/// A required Cosmos container and the partition-key path it must be created
/// with when it is missing.
///
/// The path must match how the store writes the container's documents (the
/// field Cosmos extracts the partition-key value from), so a container this
/// helper creates on a fresh account behaves identically to one provisioned out
/// of band with `az cosmosdb sql container create`.
class CosmosContainerSpec {
  const CosmosContainerSpec(this.name, this.partitionKeyPath);

  /// The container id (e.g. [decisionsContainer]).
  final String name;

  /// The partition-key path (e.g. `/pk` or `/id`).
  final String partitionKeyPath;
}

/// The materialized-view containers [CosmosLinkedStore] reads and writes: the
/// per-account and per-group docs, the rollups, the operator [decisionsContainer]
/// (#109/#110), and the shared [syncStateContainer] (generation + sync/drift
/// lease, #108).
///
/// Every one is partitioned by `/pk` — the field each document carries the
/// partition value in — except [syncStateContainer], whose singleton documents
/// are their own partition and are keyed by `/id`.
const List<CosmosContainerSpec> linkedStoreContainers = [
  CosmosContainerSpec(linkedAccountsContainer, '/pk'),
  CosmosContainerSpec(linkedGroupsContainer, '/pk'),
  CosmosContainerSpec(rollupsContainer, '/pk'),
  CosmosContainerSpec(decisionsContainer, '/pk'),
  CosmosContainerSpec(syncStateContainer, '/id'),
];

/// Ensures every container in [specs] exists, creating any that are missing.
///
/// The materialized-view containers are provisioned out of band on the shared
/// account (`docs/port-plan.md`), but that left a gap: a container that was
/// never stood up (the operator [decisionsContainer] among the epic-#112 cold
/// containers) surfaced only as a **404 on the first item write** — e.g.
/// accepting a duplicate-mail collision, which then failed silently and
/// re-warned on the next read (#150). Ensuring the containers at bootstrap
/// closes that gap: a correctly-provisioned account finds them all present
/// (a cheap metadata read, no create attempted), a fresh account has them
/// created, and an account where they are genuinely missing and cannot be
/// created surfaces the problem loudly at startup instead of on a later click.
Future<void> ensureContainers(
  CosmosClient client, {
  List<CosmosContainerSpec> specs = linkedStoreContainers,
}) async {
  for (final spec in specs) {
    await client.ensureContainer(
      container: spec.name,
      partitionKeyPath: spec.partitionKeyPath,
    );
  }
}
