/// Smartschool SOAP (V3) connector for the Arcadia Account Manager port.
///
/// Reads the group tree and student/staff/co-account records into an
/// immutable `SmartschoolSnapshot`, and performs the account, password,
/// group, membership, and lifecycle writes the legacy action set depends on.
/// Pure Dart — no Flutter, no UI coupling. See
/// `packages/smartschool_api/README.md` for the SOAP approach and design
/// notes.
///
/// Spec: `docs/domain-model.md` §3.5, §3.7, §3.11. Legacy reference
/// (read-only): `legacy-wpf/AccountApi/Smartschool/`.
library;

export 'src/config/live_config.dart' show SmartschoolLiveConfig;
export 'src/connector.dart' show SmartschoolConnector, SmartschoolMethod;
export 'src/errors/error_codes.dart' show SmartschoolErrorCodes;
export 'src/models/co_account_slot.dart' show CoAccountSlot;
export 'src/models/smartschool_account.dart' show SmartschoolAccount;
export 'src/models/smartschool_group.dart' show SmartschoolGroup;
export 'src/models/smartschool_membership.dart' show SmartschoolMembership;
export 'src/parsing/account_json.dart'
    show parseSmartschoolAccount, parseSmartschoolAccounts;
export 'src/parsing/date_format.dart'
    show formatSmartschoolDate, parseSmartschoolDate;
export 'src/parsing/group_tree.dart' show parseGroupTree;
export 'src/parsing/mappings.dart'
    show
        UnsupportedSmartschoolRole,
        accountStateFromStatus,
        disabledStatus,
        formatStamboek,
        genderFromSmartschool,
        parseStamboek,
        personRoleFromBasisrol,
        smartschoolGender,
        smartschoolRole,
        statusFromAccountState;
export 'src/rules/import_rules.dart'
    show
        DiscardSmartschoolGroup,
        NoSmartschoolSubgroups,
        SmartschoolImportRule,
        applyImportRules;
export 'src/snapshot.dart' show SmartschoolSnapshot;
export 'src/soap/credentials.dart' show SmartschoolCredentials, SoapArg;
export 'src/soap/soap_envelope.dart'
    show
        SmartschoolSoapFault,
        SmartschoolSoapResponseException,
        SoapReturn,
        buildRpcEnvelope,
        decodeIntResult,
        decodeReturn,
        soapActionFor;
export 'src/soap/soap_transport.dart'
    show
        HttpSmartschoolSoapTransport,
        SmartschoolSoapHttpException,
        SmartschoolSoapTransport,
        redactAccessCode;
