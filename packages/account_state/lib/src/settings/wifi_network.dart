/// One WiFi network as it is printed on a password sheet: the SSID the reader
/// joins and the shared key they type (#368).
///
/// **Deliberately not a secret.** The key is handed to every student on paper,
/// so it lives in the settings document beside the rest of the configuration
/// rather than in Key Vault behind a [SecretProvider]: modelling it as a secret
/// would be theatre, and — because a secret is write-only in the UI — would hide
/// the one value the operator opens Instellingen to check.
class WifiNetwork {
  const WifiNetwork({this.ssid = '', this.code = ''});

  /// The network name printed on the sheet.
  final String ssid;

  /// The shared key printed under it. May legitimately be empty — an open
  /// network still has a name worth printing.
  final String code;

  /// Whether this network is printed at all.
  ///
  /// The SSID alone decides: without a network name the block would say
  /// `Netwerk :` and nothing else, so the whole block is omitted instead — the
  /// same way the Office 365 and Smartschool blocks disappear when there is no
  /// password to show.
  bool get isConfigured => ssid.trim().isNotEmpty;

  WifiNetwork copyWith({String? ssid, String? code}) => WifiNetwork(
        ssid: ssid ?? this.ssid,
        code: code ?? this.code,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ssid': ssid,
        'code': code,
      };

  factory WifiNetwork.fromJson(Map<String, dynamic> json) => WifiNetwork(
        ssid: (json['ssid'] as String?) ?? '',
        code: (json['code'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is WifiNetwork && other.ssid == ssid && other.code == code;

  @override
  int get hashCode => Object.hash(ssid, code);

  @override
  String toString() => 'WifiNetwork($ssid)';
}

/// The student network the sheets printed before it was configurable (#368).
///
/// Kept as the fallback for a settings document written before this existed:
/// dropping it would mean every sheet generated between the upgrade and the
/// operator's first visit to Instellingen loses its WiFi block, silently.
const WifiNetwork defaultStudentWifi = WifiNetwork(
  ssid: 'Smifi-L',
  code: 'SmifiDeWifi:)',
);

/// The staff network the sheets printed before it was configurable (#368) —
/// the [defaultStudentWifi] counterpart, and the same upgrade fallback.
const WifiNetwork defaultStaffWifi = WifiNetwork(
  ssid: 'Smifi-P',
  code: '!TEAM!SMA!',
);
