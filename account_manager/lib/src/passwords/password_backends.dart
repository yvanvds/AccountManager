import 'package:account_core/account_core.dart' as core;
import 'package:azure_api/azure_api.dart' as az;
import 'package:smartschool_api/smartschool_api.dart' as ss;

/// The live write seam for on-demand password generation (#180).
///
/// On-demand generation pushes fresh passwords straight to Smartschool and
/// Azure. Those writes are write-capable and, per the project's live-testing
/// policy, are exercised manually against the real school APIs — never in CI.
/// Splitting them behind this interface lets [PasswordController] be driven
/// headlessly (a fake records the pushes and reports success/failure) while
/// production wires [ConnectorPasswordBackends] to the real connectors.
abstract interface class PasswordBackends {
  /// Sets [uid]'s Smartschool [slot] password (the main account uses
  /// [core.AccountType.student]; co-accounts use `coAccount1..6`). Returns
  /// `true` on success.
  Future<bool> setSmartschoolPassword(
    String uid,
    core.AccountType slot,
    String password,
  );

  /// Resets the Azure / Office 365 password of the user identified by
  /// [mailOrUpn]. Returns `true` when the user was found and updated, `false`
  /// when no such user exists (mirroring the legacy "No account for …" skip).
  ///
  /// Throws [az.AzurePasswordPermissionException] when the directory refuses
  /// the write (#216). That is a permission/role gap the operator can act on,
  /// not a missing account, so it is signalled rather than folded into `false`:
  /// the caller names the cause on screen instead of reporting a bare "niet
  /// gezet".
  Future<bool> setAzurePassword(String mailOrUpn, String password);
}

/// The production [PasswordBackends]: writes through the real connectors.
///
/// A `null` connector (the system is not configured for this build) makes the
/// corresponding push a no-op that returns `false`, so the controller reports
/// "not pushed" rather than crashing.
class ConnectorPasswordBackends implements PasswordBackends {
  ConnectorPasswordBackends({this.smartschool, this.azure, this.log});

  final ss.SmartschoolConnector? smartschool;
  final az.AzureConnector? azure;
  final core.ILog? log;

  @override
  Future<bool> setSmartschoolPassword(
    String uid,
    core.AccountType slot,
    String password,
  ) async {
    final connector = smartschool;
    if (connector == null) return false;
    return connector.setPassword(uid, slot, password);
  }

  @override
  Future<bool> setAzurePassword(String mailOrUpn, String password) async {
    final connector = azure;
    if (connector == null) return false;
    // Mirror legacy StudentPasswords: look the user up by principal name, skip
    // (and log) when there is no Azure account, otherwise reset the password.
    final user = await connector.users.getUser(mailOrUpn);
    if (user == null) {
      log?.addError(core.Origin.azure, 'Geen Azure-account voor $mailOrUpn.');
      return false;
    }
    await connector.users.setPassword(user.id, password);
    return true;
  }
}
