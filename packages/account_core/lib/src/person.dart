import 'enums.dart';
import 'ids.dart';

/// Postal address.
///
/// Belgian-format by convention (see `docs/domain-model.md` OQ-2). Fields
/// mirror the WISA CSV columns 12-16. The [streetAddress] getter formats the
/// address as a single string the way the Smartschool connector requires
/// (legacy reference: `legacy-wpf/AccountApi/Smartschool/AccountManager.cs`
/// lines 57-59).
class Address {
  final String street;
  final String houseNumber;
  final String? houseNumberAdd;
  final String postalCode;
  final String city;
  final String country;

  const Address({
    required this.street,
    required this.houseNumber,
    this.houseNumberAdd,
    required this.postalCode,
    required this.city,
    required this.country,
  });

  /// One-line "street + houseNumber[/add]" format used by the Smartschool
  /// connector. Behaviour matches legacy verbatim:
  /// - `houseNumber` is appended only when non-empty (preceded by a space).
  /// - `houseNumberAdd` is appended only when non-null and non-empty
  ///   (preceded by `/`).
  /// - An empty [street] is preserved as-is.
  String get streetAddress {
    final buf = StringBuffer(street);
    if (houseNumber.isNotEmpty) buf.write(' $houseNumber');
    final add = houseNumberAdd;
    if (add != null && add.isNotEmpty) buf.write('/$add');
    return buf.toString();
  }

  Map<String, dynamic> toJson() => {
        'street': street,
        'houseNumber': houseNumber,
        if (houseNumberAdd != null) 'houseNumberAdd': houseNumberAdd,
        'postalCode': postalCode,
        'city': city,
        'country': country,
      };

  factory Address.fromJson(Map<String, dynamic> json) => Address(
        street: json['street'] as String,
        houseNumber: json['houseNumber'] as String,
        houseNumberAdd: json['houseNumberAdd'] as String?,
        postalCode: json['postalCode'] as String,
        city: json['city'] as String,
        country: json['country'] as String,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Address &&
          street == other.street &&
          houseNumber == other.houseNumber &&
          houseNumberAdd == other.houseNumberAdd &&
          postalCode == other.postalCode &&
          city == other.city &&
          country == other.country;

  @override
  int get hashCode => Object.hash(
        street,
        houseNumber,
        houseNumberAdd,
        postalCode,
        city,
        country,
      );
}

/// The canonical record of a human — student or staff — independent of which
/// per-system accounts (WISA, Smartschool, Azure) hold them.
///
/// Spec: `docs/domain-model.md` §3.1. `mail` deliberately does **not** live
/// here; it belongs to the Azure account.
class Person {
  final PersonId id;
  final PersonRole role;
  final String givenName;
  final String surname;
  final String? preferredName;
  final Gender gender;
  final DateTime? birthDate;
  final String? birthPlace;
  final String? birthCountry;
  final Address? address;
  final String? mobilePhone;
  final String? homePhone;
  final String? nationalId;

  const Person({
    required this.id,
    required this.role,
    required this.givenName,
    required this.surname,
    this.preferredName,
    required this.gender,
    this.birthDate,
    this.birthPlace,
    this.birthCountry,
    this.address,
    this.mobilePhone,
    this.homePhone,
    this.nationalId,
  });

  Map<String, dynamic> toJson() => {
        'id': id.toJson(),
        'role': role.toJson(),
        'givenName': givenName,
        'surname': surname,
        if (preferredName != null) 'preferredName': preferredName,
        'gender': gender.toJson(),
        if (birthDate != null) 'birthDate': birthDate!.toIso8601String(),
        if (birthPlace != null) 'birthPlace': birthPlace,
        if (birthCountry != null) 'birthCountry': birthCountry,
        if (address != null) 'address': address!.toJson(),
        if (mobilePhone != null) 'mobilePhone': mobilePhone,
        if (homePhone != null) 'homePhone': homePhone,
        if (nationalId != null) 'nationalId': nationalId,
      };

  factory Person.fromJson(Map<String, dynamic> json) => Person(
        id: PersonId(json['id'] as String),
        role: PersonRole.fromJson(json['role'] as String),
        givenName: json['givenName'] as String,
        surname: json['surname'] as String,
        preferredName: json['preferredName'] as String?,
        gender: Gender.fromJson(json['gender'] as String),
        birthDate: json['birthDate'] == null
            ? null
            : DateTime.parse(json['birthDate'] as String),
        birthPlace: json['birthPlace'] as String?,
        birthCountry: json['birthCountry'] as String?,
        address: json['address'] == null
            ? null
            : Address.fromJson(json['address'] as Map<String, dynamic>),
        mobilePhone: json['mobilePhone'] as String?,
        homePhone: json['homePhone'] as String?,
        nationalId: json['nationalId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Person &&
          id == other.id &&
          role == other.role &&
          givenName == other.givenName &&
          surname == other.surname &&
          preferredName == other.preferredName &&
          gender == other.gender &&
          birthDate == other.birthDate &&
          birthPlace == other.birthPlace &&
          birthCountry == other.birthCountry &&
          address == other.address &&
          mobilePhone == other.mobilePhone &&
          homePhone == other.homePhone &&
          nationalId == other.nationalId;

  @override
  int get hashCode => Object.hashAll([
        id,
        role,
        givenName,
        surname,
        preferredName,
        gender,
        birthDate,
        birthPlace,
        birthCountry,
        address,
        mobilePhone,
        homePhone,
        nationalId,
      ]);
}
