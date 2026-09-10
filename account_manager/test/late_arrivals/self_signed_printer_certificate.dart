/// A self-signed certificate and key, so a test can stand up a TLS server that
/// looks like the reception printer does (#424).
///
/// The TM-m30III serves a certificate it signed itself — there is no CA to
/// trust and no way to get one onto a printer in a school corridor — which is
/// why `IppTicketTransport` accepts a bad certificate for the host and port it
/// was addressed to. Proving that scoping needs a real TLS handshake against a
/// real untrusted certificate, and a build agent has none.
///
/// So one is checked in. `CN=localhost`, `subjectAltName` covering `localhost`
/// and `127.0.0.1`, valid for a century, signed by nothing. **It is a test
/// fixture and nothing else**: the key below is public, in a public repository,
/// and guards a listener bound to loopback on an ephemeral port for the
/// duration of one test. It never leaves `test/`.
///
/// Regenerate with:
/// ```
/// openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
///   -days 36500 -nodes -subj "/CN=localhost" \
///   -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
/// ```
library;

import 'dart:convert';
import 'dart:io';

/// The certificate the fake printer presents.
const String selfSignedPrinterCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIIDJzCCAg+gAwIBAgIUBPHz7suTGA42BO2VCRjJVzjXr98wDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDkxMDEwNTUxMVoYDzIxMjYw
ODE3MTA1NTExWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQC2jSLdG72LoW7WUxPh79KIpz+Yh6Ab7tKmwBOciJvv
9sYtNxq0iX+ywamqFVz5N8q85sPwUoxvWHAozq1ssMewPeEOsMXvXUNfm6sJeESY
7lbgBOPKa9RixenFajTI9y5KGVL1bpP7Gky/w/aNSFDxLtsjSQEzycr/ACfVv/o6
g1yQI29obqefK+FUEy0zfzJh/k9yqkLLrVUsgzmKcqktFOf0BcVyaeL3tov0P+lO
J8ADUL46T/jmM+JSmL5+LgcHlHtEkklz8Qh5x1DFgBRtHqi+GGR8W1S03SciDZMc
kJMrtioR2u1AnX0t3rzx+UAmwCuPyIVqW7suGKQhropZAgMBAAGjbzBtMB0GA1Ud
DgQWBBQVLjXLntl4J1PhXKFzdv9+kHcqdTAfBgNVHSMEGDAWgBQVLjXLntl4J1Ph
XKFzdv9+kHcqdTAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9z
dIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEANKCReaIPZRa4N/EbKvH2sXLyEG+B
c4DxJ8QfQZj6NhJc0B945Navn98ujquxpBMb19dEps27Q/Ef0KMHndpnEscIakWN
4U6oRbwQ4dFfbYYH+sGYIowtqhOEwD7DQjJPCxZ1QyDRyRn4wvGCJ4JUHpEVIrIt
JRo+IMLEstt6inujlJjp7EIEI044LHx2aBAfhovGvjhDBzw8cf3fxsjy+BPfaFe4
pktBAklR0MmhJcDRnF3xXrtiCWNBnOYjjAfebIwE2zxePFuELdE9KSwaXegO4xoA
gMGR39PYWXXOehfHsP5C3E+Wx+bEqjQH9F2bZjiBUpy3MPRq3qVQ7jLUug==
-----END CERTIFICATE-----
''';

/// Its private key. Public by design — see the library comment.
const String selfSignedPrinterKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC2jSLdG72LoW7W
UxPh79KIpz+Yh6Ab7tKmwBOciJvv9sYtNxq0iX+ywamqFVz5N8q85sPwUoxvWHAo
zq1ssMewPeEOsMXvXUNfm6sJeESY7lbgBOPKa9RixenFajTI9y5KGVL1bpP7Gky/
w/aNSFDxLtsjSQEzycr/ACfVv/o6g1yQI29obqefK+FUEy0zfzJh/k9yqkLLrVUs
gzmKcqktFOf0BcVyaeL3tov0P+lOJ8ADUL46T/jmM+JSmL5+LgcHlHtEkklz8Qh5
x1DFgBRtHqi+GGR8W1S03SciDZMckJMrtioR2u1AnX0t3rzx+UAmwCuPyIVqW7su
GKQhropZAgMBAAECggEABmWf0kjRuNLXBmtbww5YHch8ld/+aC3Gug5F8ajA2PHl
Fzo7DsoFsuVbiG836ZZld2UMk/9hVljueNbOcXfCNTnjfDpzr5pggF+jjyqkse/V
YZ0r2h2ytnGSHYQ5Ms4+OncBaiihYDDkMR3qsrmh90p2Zkz9d4urkYmEG9beuI4I
3AKG1S6YpSPmJ/+4wOE+J64QChDHyKV+AWwonez7lF/gHfBrOujJ10cWvN4rHJgN
qUKE0D/M+gBbCIWWt35S7oOg1RDoTBlmibWsyyZU25gVWv8q3GZ/UaeBorHuni2j
ENnyEgfW2LUqgzLnb29/9i5n56uYVmpdhghKD299vQKBgQD6qI6e9CTa6Hr+5Z3Q
g/B17rWLijC4usv2GCS+8ZHfX1fATu2sj0igRTXo7gZMU4DRFwZ0ZcGZdkRpyGKI
6d7uWUOFC49WYubH0nJsNv6Uvww+L10W+sz2D1fFi/py88sr1+CrV5RMRrc57q6o
R+Z9/BlEPqe0BTzhz3RHXEGQ9QKBgQC6cQb7+MZJv0k7qijUvCHJGCBcOasfN6to
ZZ58rvXsNtEl8utpZPhM33HK61OG7E9BOJKJPSdl6G6+xmpDIAdInARgK+XmBKDA
cYi0VNEIaeh2xuwCZ9xrgS8dT0s7v1AaTrjCxFc35GxOExrDeDmP4NmrVMX3vuCI
OtSTHF4lVQKBgQDuibowSudH7DYgnSOya91KXgEm6juzkRDJAfD2Ra4shO9dc797
mF/lJfhH0zzrJgxQ7ziVTMEQ6hvxD2G2KdqduRUoZ/fgnf5B62Q4150usSFVjH1q
gQLMp40/0hZljtyqvKZyaMYYULPNzfco7kPLYT4qU/YEu3dU7bgasRE0gQKBgCHS
eVLimY4tXmqtfsTA8FwbvVsdtxZtsfG5ZZv23XQhqaV5wQ0YnRbM/kaylC+I1QPe
8G5nIquRE+4V7pcIy2l3rC+KJyWoN0VSE1ure1RMajiJ86yoDMuP3u0xQlOvbCep
mkjy92OTU7aCLrvBJqgcQUCcm2FLRk5QZdneLpIVAoGBAMkamzGK+X355GgUbItI
6jOYsMAy/R0/H6jrxSSvdcL9DfS5lnJtajTYAhjwecOmlyTaU2e2g6vsLp+um4OM
x+9pOgWQUAN4reClOztO7o6H0BeOWfAB+Ziwjjq2+Re2DfHq7P1PVikzGLzkAq69
b8X151tbJMLIdAs9YB72sNbt
-----END PRIVATE KEY-----
''';

/// A [SecurityContext] serving the fixture above, for `HttpServer.bindSecure`.
SecurityContext selfSignedPrinterContext() => SecurityContext()
  ..useCertificateChainBytes(utf8.encode(selfSignedPrinterCertificatePem))
  ..usePrivateKeyBytes(utf8.encode(selfSignedPrinterKeyPem));
