/// Persistence layer for the Arcadia Account Manager port.
///
/// Provides a file-backed `PersonIdResolver` so that UUID minting and disk
/// I/O are quarantined behind `account_core`'s injected interface, keeping the
/// linker a pure function (OQ-3, INV-20).
library;

export 'src/file_person_id_resolver.dart';
