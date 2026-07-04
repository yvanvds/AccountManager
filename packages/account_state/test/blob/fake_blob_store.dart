import 'package:account_state/account_state.dart';

/// An in-memory [BlobStore] that models write / read / idempotent-delete by
/// name, so the `CosmosSnapshotStore` overflow path is testable with no storage
/// account. Records the write count and the last content written per name so a
/// test can assert the overflow actually hit Blob rather than staying inline.
class FakeBlobStore implements BlobStore {
  final Map<String, String> _blobs = <String, String>{};

  int writes = 0;
  int reads = 0;
  int deletes = 0;

  /// Direct peek for assertions.
  String? contentOf(String ref) => _blobs[ref];

  int get count => _blobs.length;

  @override
  Future<String> write(String name, String content) async {
    writes++;
    _blobs[name] = content;
    return name;
  }

  @override
  Future<String?> read(String ref) async {
    reads++;
    return _blobs[ref];
  }

  @override
  Future<void> delete(String ref) async {
    deletes++;
    _blobs.remove(ref);
  }
}
