import 'package:account_core/account_core.dart' as core;

import '../models/wisa_class_group.dart';
import '../models/wisa_school.dart';
import '../models/wisa_staff.dart';
import '../models/wisa_student.dart';
import 'csv_parser.dart';
import 'date_format.dart';

/// Header expected at the top of a `SmaSyncLln` CSV response.
const String studentCsvHeader =
    'KLAS,KLASGROEP,NAAM,VOORNAAM,ROEPNAAM,GEBOORTEDATUM,WISAID,STAMBOEKNUMMER,'
    'GESLACHT,RIJKSREGISTERNR,GEBOORTEPLAATS,NATIONALITEIT,STRAAT,STRAATNR,'
    'BUSNR,POSTCODE,WOONPLAATS,KLASWIJZIGING';

/// Header expected at the top of a `SmaSyncPer` CSV response.
const String staffCsvHeader = 'CODE,WISAID,FAMILIENAAM,VOORNAAM';

/// Header expected at the top of a `SyncKlas` CSV response.
const String classGroupCsvHeader =
    'KLAS,KLASGROEP,OMSCHRIJVING,ADMINGROEP,INSTELLINGSNUMMER';

/// Header expected at the top of a `SMAGetInst` CSV response. Note that
/// the WISA-side column order is `ID,NAME,DESCRIPTION` but the legacy
/// connector swaps NAME and DESCRIPTION when constructing the model; we
/// preserve that.
const String schoolCsvHeader = 'ID,NAME,DESCRIPTION';

/// Parses a `SmaSyncLln` row into a [WisaStudent].
///
/// [schoolId] is the WISA school the row was fetched for — not present in
/// the CSV itself. Throws [CsvRowParseException] if the row is malformed.
///
/// WISA emits the free-text columns (NAAM, VOORNAAM, ROEPNAAM, and the
/// address block) unquoted even when they contain a literal comma — e.g. a
/// ROEPNAAM of `Michelle, Servais` — which splits the row into more than the
/// 18 header columns and, under fixed positional indices, shifts every
/// subsequent column so GEBOORTEDATUM lands on a name fragment (issue #148,
/// same failure class as #29 for class groups).
///
/// The two `d/M/yyyy` columns are the only typed landmarks that free text
/// never mimics: GEBOORTEDATUM is the first date, and KLASWIJZIGING is the
/// last column. We anchor on GEBOORTEDATUM — everything before it is the
/// name block (KLAS, KLASGROEP, NAAM, VOORNAAM, ROEPNAAM), and the 13 typed,
/// comma-free columns from GEBOORTEDATUM to KLASWIJZIGING follow it in order.
WisaStudent parseStudentRow(String line, {required int schoolId}) {
  try {
    final f = splitCsvLine(line);
    // GEBOORTEDATUM sits at column 5 in a clean row; an unquoted comma in a
    // name column pushes it right. It is the first date-shaped field.
    final dateCol = f.indexWhere((v) => tryParseBelgianDate(v) != null);
    if (dateCol < 5) {
      throw CsvRowParseException(
        line,
        'Could not locate GEBOORTEDATUM (no d/M/yyyy field at or after '
        'column 5)',
      );
    }
    // From GEBOORTEDATUM onward the columns are all typed (dates, ids,
    // gender) or controlled-vocabulary address fields that do not contain
    // commas, so exactly 13 fields must remain, ending on KLASWIJZIGING. A
    // different count means a comma leaked from the address block — we throw
    // a precise error rather than silently misalign the address.
    if (f.length - dateCol != 13) {
      throw CsvRowParseException(
        line,
        'Expected 13 columns from GEBOORTEDATUM onward, got '
        '${f.length - dateCol}',
      );
    }
    // NAAM and VOORNAAM come from single official-registry fields; any comma
    // in the name block belongs to the human-entered ROEPNAAM, which absorbs
    // the overflow (mirrors the OMSCHRIJVING rejoin in parseClassGroupRow).
    return WisaStudent(
      classGroup: f[0].trim(),
      classSubGroup: f[1].trim(),
      name: f[2].trim(),
      firstName: f[3].trim(),
      preferredName: f.sublist(4, dateCol).join(',').trim(),
      birthDate: parseBelgianDate(f[dateCol]),
      wisaId: core.WisaId(f[dateCol + 1].trim()),
      stemId: f[dateCol + 2].trim(),
      gender:
          f[dateCol + 3].trim() == 'M' ? core.Gender.male : core.Gender.female,
      nationalId: f[dateCol + 4].trim(),
      birthPlace: f[dateCol + 5].trim(),
      nationality: f[dateCol + 6].trim(),
      address: core.Address(
        street: f[dateCol + 7].trim(),
        houseNumber: f[dateCol + 8].trim(),
        houseNumberAdd:
            f[dateCol + 9].trim().isEmpty ? null : f[dateCol + 9].trim(),
        postalCode: f[dateCol + 10].trim(),
        city: f[dateCol + 11].trim(),
        country: 'BE',
      ),
      classChange: parseBelgianDate(f[dateCol + 12]),
      schoolId: schoolId,
    );
  } on CsvRowParseException {
    rethrow;
  } catch (e) {
    throw CsvRowParseException(line, e.toString());
  }
}

/// Parses a `SmaSyncPer` row into a [WisaStaff]. `WISAID` may be empty,
/// in which case [WisaStaff.wisaId] is `null`.
WisaStaff parseStaffRow(String line) {
  try {
    final f = splitCsvLine(line);
    if (f.length < 4) {
      throw CsvRowParseException(
        line,
        'Expected 4 columns, got ${f.length}',
      );
    }
    final wisaIdRaw = f[1].trim();
    return WisaStaff(
      code: core.WisaStaffCode(f[0].trim()),
      wisaId: wisaIdRaw.isEmpty ? null : core.WisaId(wisaIdRaw),
      lastName: f[2].trim(),
      firstName: f[3].trim(),
    );
  } on CsvRowParseException {
    rethrow;
  } catch (e) {
    throw CsvRowParseException(line, e.toString());
  }
}

/// Parses a `SyncKlas` row into a [WisaClassGroup].
///
/// WISA emits `OMSCHRIJVING` (the description) unquoted even when it
/// contains a literal comma — e.g. `5 Onthaal, organisatie en sales` —
/// which splits the row into more than the five header columns and, in the
/// naive parser, shifts `ADMINGROEP` and `INSTELLINGSNUMMER` (issue #29).
/// `OMSCHRIJVING` is the only free-text column; `KLAS`, `KLASGROEP`,
/// `ADMINGROEP`, and `INSTELLINGSNUMMER` are codes that never contain a
/// comma. So we anchor on the first two and last two columns and rejoin
/// everything in between as the description. A properly quoted description
/// (should WISA ever quote it) yields exactly five fields and parses
/// identically.
WisaClassGroup parseClassGroupRow(String line, {required int schoolId}) {
  try {
    final f = splitCsvLine(line);
    if (f.length < 5) {
      throw CsvRowParseException(
        line,
        'Expected 5 columns, got ${f.length}',
      );
    }
    return WisaClassGroup(
      name: f[0].trim(),
      groupName: f[1].trim(),
      description: f.sublist(2, f.length - 2).join(',').trim(),
      adminCode: f[f.length - 2].trim(),
      schoolCode: f[f.length - 1].trim(),
      schoolId: schoolId,
    );
  } on CsvRowParseException {
    rethrow;
  } catch (e) {
    throw CsvRowParseException(line, e.toString());
  }
}

/// Parses a `SMAGetInst` row into a [WisaSchool]. Preserves the legacy
/// quirk: column 1 (`NAME`) becomes the school's `description` and column
/// 2 (`DESCRIPTION`) becomes its `name`.
WisaSchool parseSchoolRow(String line) {
  try {
    final f = splitCsvLine(line);
    if (f.length < 3) {
      throw CsvRowParseException(
        line,
        'Expected 3 columns, got ${f.length}',
      );
    }
    final id = int.tryParse(f[0].trim());
    if (id == null) {
      throw CsvRowParseException(line, 'School ID is not an integer');
    }
    return WisaSchool(
      id: id,
      description: f[1].trim(),
      name: f[2].trim(),
    );
  } on CsvRowParseException {
    rethrow;
  } catch (e) {
    throw CsvRowParseException(line, e.toString());
  }
}
