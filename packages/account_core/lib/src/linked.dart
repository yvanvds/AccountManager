import 'enums.dart';
import 'group.dart';
import 'ids.dart';
import 'source_records.dart';

/// How confident the linker is that a [LinkedAccount] is correct.
///
/// Spec `docs/domain-model.md` §3.9. Replaces the implicit "alumni" /
/// "placeholder" states that legacy encodes by which fields happen to be
/// null.
enum LinkConfidence {
  /// All linking keys agreed (e.g. `upn == mail` AND `employeeId == wisaId`).
  high,

  /// Some signal is missing or weak — typically an Azure-only alumni record
  /// or a WISA-only placeholder for a student who hasn't been provisioned in
  /// Smartschool yet.
  medium,
  ;

  String toJson() => name;
  static LinkConfidence fromJson(String s) => values.byName(s);
}

/// Output of the linker: one record per identified person.
///
/// Any of [wisa], [smartschool], [azure] may be null; when all three are
/// present the linker has unified the systems' views of this person. When
/// one is missing, the action engine raises the matching add/remove action.
class LinkedAccount {
  final LinkedAccountId id;
  final PersonRole role;
  final WisaStudent? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;

  const LinkedAccount({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
  });
}

/// Output of the linker: one record per identified staff member.
///
/// Distinguished from [LinkedAccount] because staff use [WisaStaff] (with
/// its [WisaStaffCode]) instead of [WisaStudent].
class LinkedStaff {
  final LinkedAccountId id;
  final PersonRole role;
  final WisaStaff? wisa;
  final SmartschoolAccount? smartschool;
  final AzureUser? azure;
  final LinkConfidence confidence;

  const LinkedStaff({
    required this.id,
    required this.role,
    this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
  });
}

/// Output of the linker: one record per identified group.
class LinkedGroup {
  final Group wisa;
  final Group? smartschool;
  final AzureGroup? azure;
  final LinkConfidence confidence;

  const LinkedGroup({
    required this.wisa,
    this.smartschool,
    this.azure,
    required this.confidence,
  });
}
