import 'package:azure_api/azure_api.dart' show AzureConnector;
import 'package:smartschool_api/smartschool_api.dart' show SmartschoolConnector;

/// The write-capable connectors an action's `apply()` may call.
///
/// WISA is intentionally absent: the WISA connector is read-only (a CSV
/// export), so no student action writes to it. The `smartschool`/`azure`
/// connectors are nullable so a caller can wire only the systems it needs; an
/// action whose target connector is missing throws `StateError` at apply time
/// (a wiring bug, not a transient failure).
class Connectors {
  final SmartschoolConnector? smartschool;
  final AzureConnector? azure;

  const Connectors({this.smartschool, this.azure});
}
