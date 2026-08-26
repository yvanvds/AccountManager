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

  /// Resets the Azure / Office 365 password of the user with Graph object id
  /// [objectId] — **the account the linker attached to this person** (#372).
  ///
  /// This is the write the Passwords screen performs whenever a linked snapshot
  /// is in hand. The lookup-by-address variant below cannot be trusted to find
  /// the right account: a Smartschool `mail` and an Azure `userPrincipalName`
  /// drift apart (a collision suffix, a private address, a differently folded
  /// accent), and a `GET /users/<smartschool mail>` then answers
  /// `Request_ResourceNotFound` for a student who *has* an Office 365 account.
  /// The `employeeId ≡ wisaId` bridge already resolved that account; taking the
  /// object id from the linked record uses it instead of guessing again.
  ///
  /// Returns `true` when the write landed, `false` when it did not. Throws
  /// [az.AzurePasswordPermissionException] on a refusal, as below.
  Future<bool> setAzurePasswordById(String objectId, String password);

  /// Resets the Azure / Office 365 password of the user identified by
  /// [mailOrUpn]. Returns `true` when the user was found and updated, `false`
  /// when no such user exists (mirroring the legacy "No account for …" skip).
  ///
  /// The **fallback** since #372: used only while this session holds no linked
  /// snapshot to resolve the account through, which is the one situation in
  /// which an address is the best key available.
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
  Future<bool> setAzurePasswordById(String objectId, String password) async {
    final connector = azure;
    if (connector == null || objectId.isEmpty) return false;
    // No lookup: the linker already resolved this account, and Graph accepts an
    // object id wherever it accepts a principal name (#372).
    await connector.users.setPassword(objectId, password);
    return true;
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
