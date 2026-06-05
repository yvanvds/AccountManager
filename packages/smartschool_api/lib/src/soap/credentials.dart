/// Connection identity for the Smartschool SOAP (V3) service.
///
/// Unlike WISA (username + password + database), Smartschool authenticates
/// every call with a single *accesscode* passphrase, configured per tenant
/// in the school's Smartschool web-services settings. The [site] is the
/// tenant subdomain (e.g. `sanctamaria-aarschot` for
/// `https://sanctamaria-aarschot.smartschool.be`).
///
/// Legacy reference: `legacy-wpf/AccountApi/Smartschool/Connector.cs`
/// (`Init(site, password, log)`).
class SmartschoolCredentials {
  /// Tenant subdomain — the part before `.smartschool.be`.
  final String site;

  /// The per-tenant accesscode passphrase, passed as the first argument of
  /// every SOAP call.
  final String accessCode;

  const SmartschoolCredentials({
    required this.site,
    required this.accessCode,
  });

  /// The SOAP endpoint URL: `https://<site>.smartschool.be/Webservices/V3`.
  Uri get endpoint =>
      Uri.parse('https://$site.smartschool.be/Webservices/V3');

  /// The RPC namespace used by every operation in the V3 WSDL. Smartschool
  /// bakes the tenant URL into the namespace (the generated .NET stub uses
  /// `https://<site>.smartschool.be/Webservices/V3`), so it is derived from
  /// [site] rather than hard-coded.
  String get namespace => 'https://$site.smartschool.be/Webservices/V3';
}

/// One named argument of a Smartschool RPC call.
///
/// RPC/encoded SOAP names each argument by its WSDL message-part name
/// (`accesscode`, `userIdentifier`, `passwd1`, …), in declaration order.
/// [xsiType] is the SOAP-encoding type written on the element; most parts
/// are `xsd:string`, a few (`accountType`, `keepOld`) are `xsd:int`.
class SoapArg {
  final String name;
  final String value;
  final String xsiType;

  const SoapArg.string(this.name, this.value) : xsiType = 'xsd:string';
  const SoapArg.int(this.name, int value)
      : value = '$value',
        xsiType = 'xsd:int';
}
