import 'dart:convert';

import 'package:account_core/account_core.dart' as core;

import '../models/co_account_slot.dart';
import '../models/smartschool_account.dart';
import 'date_format.dart';
import 'mappings.dart';

/// Parses the JSON payload of `getAllAccountsExtended` (a JSON array of
/// account objects) into [SmartschoolAccount]s.
///
/// Unlike the legacy `LoadFromJSON`, the six co-account slots are preserved
/// (issue #21, spec §3.5). Throws [FormatException] if [jsonText] is not a
/// JSON array.
List<SmartschoolAccount> parseSmartschoolAccounts(String jsonText) {
  final decoded = json.decode(jsonText);
  if (decoded is! List) {
    throw FormatException(
      'Expected a JSON array of accounts, got ${decoded.runtimeType}',
    );
  }
  return [
    for (final e in decoded)
      parseSmartschoolAccount(e as Map<String, dynamic>),
  ];
}

/// Parses a single decoded account object into a [SmartschoolAccount].
///
/// Field mapping mirrors legacy `AccountManager.LoadFromJSON`
/// (`AccountManager.cs:507-575`), extended to retain co-account slots.
SmartschoolAccount parseSmartschoolAccount(Map<String, dynamic> json) {
  String s(String key) {
    final v = json[key];
    return v == null ? '' : v.toString();
  }

  final roepnaam = s('Roepnaam');

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
    coAccounts: _parseCoAccounts(json, s),
  );
}

/// Reads the six `*_coaccountN` slot groups. Empty slots are dropped, so the
/// returned list contains only populated co-accounts, in ascending slot
/// order.
List<CoAccountSlot> _parseCoAccounts(
  Map<String, dynamic> json,
  String Function(String) s,
) {
  final slots = <CoAccountSlot>[];
  for (var n = 1; n <= 6; n++) {
    final slot = CoAccountSlot(
      slot: n,
      firstName: s('Voornaam_coaccount$n'),
      lastName: s('Naam_coaccount$n'),
      email: s('Email_coaccount$n'),
      phone: s('Telefoonnummer_coaccount$n'),
      mobile: s('Mobielnummer_coaccount$n'),
      type: s('Type_coaccount$n'),
    );
    if (!slot.isEmpty) slots.add(slot);
  }
  return slots;
}
