/// WISA SOAP connector for the Arcadia Account Manager port.
///
/// Pulls students, staff, class groups, and schools from a school's WISA
/// instance and produces immutable `WisaSnapshot`s. Pure Dart — no Flutter,
/// no UI coupling. See `packages/wisa_api/README.md` for the SOAP approach
/// and design notes.
///
/// Spec: `docs/domain-model.md` §3.3, §3.4, §3.11. Legacy reference
/// (read-only): `legacy-wpf/AccountApi/Wisa/`.
library;

export 'src/config/live_config.dart' show WisaLiveConfig;
export 'src/connector.dart' show WisaConnector, WisaQuery;
export 'src/csv/csv_parser.dart' show CsvHeaderMismatch, CsvRowParseException;
export 'src/models/wisa_class_group.dart';
export 'src/models/wisa_school.dart';
export 'src/models/wisa_staff.dart';
export 'src/models/wisa_student.dart';
export 'src/rules/import_rules.dart';
export 'src/snapshot.dart';
export 'src/soap/credentials.dart';
export 'src/soap/soap_envelope.dart'
    show WisaSoapFault, WisaSoapResponseException, decodeGetCsvDataResponse;
export 'src/soap/soap_transport.dart'
    show
        HttpWisaSoapTransport,
        WisaSoapHttpException,
        WisaSoapTransport,
        redactCredentials;
