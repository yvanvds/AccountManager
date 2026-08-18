import 'dart:convert';

import 'package:account_core/account_core.dart' as core;

import '../models/co_account_slot.dart';
import '../models/smartschool_account.dart';
import 'date_format.dart';
import 'mappings.dart';

/// Everything one `getAllAccountsExtended` payload carries: the account
/// records plus the Smartschool-internal group ids embedded in each account's
/// `groups` array (#138).
class SmartschoolAccountPayload {
  /// The parsed accounts, in payload order. Disabled accounts are **not**
  /// filtered here — the connector does that.
  final List<SmartschoolAccount> accounts;

  /// Smartschool's numeric group id per group code, e.g. `SSM1A: 298`,
  /// harvested from every account's `groups` array. Covers the account's whole
  /// group set, not just the group the payload was requested for, so one
  /// response resolves ids for several groups at once.
  final Map<String, int> groupIds;

  const SmartschoolAccountPayload({
    required this.accounts,
    required this.groupIds,
  });
}

/// Parses the JSON payload of `getAllAccountsExtended` (a JSON array of
/// account objects) into [SmartschoolAccount]s.
///
/// Unlike the legacy `LoadFromJSON`, the six co-account slots are preserved
/// (issue #21, spec §3.5). Throws [FormatException] if [jsonText] is not a
/// JSON array.
List<SmartschoolAccount> parseSmartschoolAccounts(String jsonText) =>
    parseSmartschoolAccountPayload(jsonText).accounts;

/// Parses a `getAllAccountsExtended` payload into its accounts *and* the group
/// ids its `groups` arrays carry, decoding the JSON only once.
///
/// Throws [FormatException] if [jsonText] is not a JSON array.
SmartschoolAccountPayload parseSmartschoolAccountPayload(String jsonText) {
  final decoded = json.decode(jsonText);
  if (decoded is! List) {
    throw FormatException(
      'Expected a JSON array of accounts, got ${decoded.runtimeType}',
    );
  }
  final accounts = <SmartschoolAccount>[];
  final groupIds = <String, int>{};
  for (final e in decoded) {
    final row = e as Map<String, dynamic>;
    accounts.add(parseSmartschoolAccount(row));
    groupIds.addAll(parseSmartschoolGroupIds(row));
  }
  return SmartschoolAccountPayload(accounts: accounts, groupIds: groupIds);
}

/// Reads the `groups` array of one decoded account object into a
/// `code → Smartschool group id` map, e.g.
/// `[{"id":"298","code":"SSM1A"},{"id":"4","code":"LLN"}]` → `{SSM1A: 298,
/// LLN: 4}` (#138).
///
/// The id arrives as a numeric string on the live wire; an int is accepted
/// too. Entries without a usable code or a numeric id are skipped — the ids
/// are informational and must never fail a sync.
Map<String, int> parseSmartschoolGroupIds(Map<String, dynamic> json) {
  final raw = _lowerKeyed(json)['groups'];
  if (raw is! List) return const {};
  final ids = <String, int>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final fields = <String, dynamic>{
      for (final e in entry.entries) e.key.toString().toLowerCase(): e.value,
    };
    final code = fields['code']?.toString().trim() ?? '';
    final id = _asInt(fields['id']);
    if (code.isEmpty || id == null) continue;
    ids[code] = id;
  }
  return ids;
}

/// Parses a single decoded account object into a [SmartschoolAccount].
///
/// Field mapping mirrors legacy `AccountManager.LoadFromJSON`
/// (`AccountManager.cs:507-575`), extended to retain co-account slots and the
/// Smartschool-internal `referenceIdentifier` (#138).
///
/// The live `getAllAccountsExtended` payload uses **lowercase** wire keys
/// (`gebruikersnaam`, `internnummer`, …). The legacy connector deserialized
/// into a typed `JSONAccount`, and Newtonsoft matches property names
/// case-insensitively — so reading `json.Gebruikersnaam` worked against the
/// lowercase wire. Dart's `json.decode` produces a case-sensitive map, so we
/// reproduce that case-insensitive lookup here. Reading the exact-cased keys
/// directly (as this parser first did) returned `null` for every field — the
/// cause of the empty/duplicate snapshot in #37.
SmartschoolAccount parseSmartschoolAccount(Map<String, dynamic> json) {
  final byLowerKey = _lowerKeyed(json);
  String s(String key) {
    final v = byLowerKey[key.toLowerCase()];
    return v == null ? '' : v.toString();
  }

  final roepnaam = s('Roepnaam');
  final reference = s('referenceIdentifier');

  return SmartschoolAccount(
    uid: s('Gebruikersnaam'),
    accountId: s('Internnummer'),
    mail: s('Emailadres'),
    registerId: s('Rijksregisternummer'),
    stemId: parseStamboek(s('Stamboeknummer')),
    role: personRoleFromBasisrol(s('Basisrol')),
    givenName: s('Voornaam'),
    surname: s('Naam'),
    extraNames: s('Extravoornamen'),
    initials: s('Initialen'),
    preferredName: roepnaam,
    gender: genderFromSmartschool(s('Geslacht')),
    birthDate: parseSmartschoolDate(s('Geboortedatum')),
    birthPlace: s('Geboorteplaats'),
    birthCountry: s('Geboorteland'),
    address: core.Address(
      street: s('Straat'),
      houseNumber: s('Huisnummer'),
      houseNumberAdd: s('Busnummer'),
      postalCode: s('Postcode'),
      city: s('Woonplaats'),
      country: s('Land'),
    ),
    mobilePhone: s('Mobielnummer'),
    homePhone: s('Telefoonnummer'),
    fax: s('Fax'),
    // Smartschool does not return UntisID via getAllAccountsExtended.
    untisId: '',
    status: s('Status'),
    // Absent on older tenants and some co-account rows: keep it null rather
    // than storing an empty string (#138).
    referenceIdentifier: reference.isEmpty ? null : reference,
    coAccounts: _parseCoAccounts(s),
  );
}

/// Lowercases every key once so lookups are case-insensitive (Newtonsoft
/// semantics). On the off chance two keys collide when lowercased, last wins.
Map<String, dynamic> _lowerKeyed(Map<String, dynamic> json) => {
      for (final entry in json.entries) entry.key.toLowerCase(): entry.value,
    };

/// Reads a wire value that may arrive as an int or as a numeric string.
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Reads the six `*_coaccountN` slot groups. Empty slots are dropped, so the
/// returned list contains only populated co-accounts, in ascending slot
/// order.
List<CoAccountSlot> _parseCoAccounts(String Function(String) s) {
  final slots = <CoAccountSlot>[];
  for (var n = 1; n <= 6; n++) {
    // Empty slots carry the integer sentinel `0` for the type (e.g.
    // `"type_coaccount3": 0`) rather than an empty string; normalise it so
    // the slot still reads as empty and is dropped below.
    final rawType = s('Type_coaccount$n');
    final slot = CoAccountSlot(
      slot: n,
      firstName: s('Voornaam_coaccount$n'),
      lastName: s('Naam_coaccount$n'),
      email: s('Email_coaccount$n'),
      phone: s('Telefoonnummer_coaccount$n'),
      mobile: s('Mobielnummer_coaccount$n'),
      type: rawType == '0' ? '' : rawType,
    );
    if (!slot.isEmpty) slots.add(slot);
  }
  return slots;
}
