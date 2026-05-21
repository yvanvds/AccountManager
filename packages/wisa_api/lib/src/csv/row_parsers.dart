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
WisaStudent parseStudentRow(String line, {required int schoolId}) {
  try {
    final f = splitCsvLine(line);
    if (f.length < 18) {
      throw CsvRowParseException(
        line,
        'Expected 18 columns, got ${f.length}',
      );
    }
    return WisaStudent(
      classGroup: f[0].trim(),
      classSubGroup: f[1].trim(),
      name: f[2].trim(),
      firstName: f[3].trim(),
      preferredName: f[4].trim(),
      birthDate: parseBelgianDate(f[5]),
      wisaId: core.WisaId(f[6].trim()),
      stemId: f[7].trim(),
      gender: f[8].trim() == 'M' ? core.Gender.male : core.Gender.female,
      nationalId: f[9].trim(),
      birthPlace: f[10].trim(),
      nationality: f[11].trim(),
      address: core.Address(
        street: f[12].trim(),
        houseNumber: f[13].trim(),
        houseNumberAdd: f[14].trim().isEmpty ? null : f[14].trim(),
        postalCode: f[15].trim(),
        city: f[16].trim(),
        country: 'BE',
      ),
      classChange: parseBelgianDate(f[17]),
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
      description: f[2].trim(),
      adminCode: f[3].trim(),
      schoolCode: f[4].trim(),
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
