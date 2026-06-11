/// Cross-system linker for the Arcadia Account Manager port.
///
/// Exposes the pure `link(wisa, smartschool, azure, resolver)` function that
/// reconciles the WISA, Smartschool, and Azure snapshots into one
/// `LinkedAccount` per person (spec `docs/domain-model.md` §6.2).
library;

export 'src/link.dart';
