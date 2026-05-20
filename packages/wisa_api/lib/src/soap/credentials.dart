/// Credentials passed to the WISA SOAP service on every call.
///
/// Mirrors the `TWISAAPICredentials` complexType in the WSDL.
class WisaCredentials {
  final String username;
  final String password;
  final String database;

  const WisaCredentials({
    required this.username,
    required this.password,
    required this.database,
  });
}

/// One element of a WISA SOAP `TWISAAPIParamValues` array.
class WisaParam {
  final String name;
  final String value;
  const WisaParam(this.name, this.value);
}
