#include "aad_broker.h"

#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "net.attr-x.arcadia/aad_broker";

// Parsed arguments common to both broker methods.
struct BrokerRequest {
  std::string client_id;
  std::string authority;
  std::vector<std::string> scopes;
};

// Reads a string from the argument map, or empty when absent.
std::string GetString(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  if (it == map.end()) return {};
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return {};
}

// Parses {clientId, authority, scopes} from a method call's arguments.
// Returns false when the payload is not the expected shape.
bool ParseRequest(const EncodableValue* args, BrokerRequest* out) {
  const auto* map = std::get_if<EncodableMap>(args);
  if (map == nullptr) return false;
  out->client_id = GetString(*map, "clientId");
  out->authority = GetString(*map, "authority");
  auto it = map->find(EncodableValue(std::string("scopes")));
  if (it != map->end()) {
    if (const auto* list = std::get_if<EncodableList>(&it->second)) {
      for (const auto& item : *list) {
        if (const auto* s = std::get_if<std::string>(&item)) {
          out->scopes.push_back(*s);
        }
      }
    }
  }
  return !out->client_id.empty() && !out->authority.empty() &&
         !out->scopes.empty();
}

// Builds the {accessToken, expiresOn, account} success map the Dart side
// (`MethodChannelAadBroker._parse`) expects.
EncodableValue TokenResult(const std::string& access_token,
                           int64_t expires_on_ms,
                           const std::string& account) {
  return EncodableValue(EncodableMap{
      {EncodableValue("accessToken"), EncodableValue(access_token)},
      {EncodableValue("expiresOn"), EncodableValue(expires_on_ms)},
      {EncodableValue("account"), EncodableValue(account)},
  });
}

}  // namespace

#ifdef HAVE_MSAL_RUNTIME
// ---------------------------------------------------------------------------
// Real WAM implementation — MSAL Runtime (msalruntime.dll) C API.
//
// NOT built in CI: it is compiled only when the MSAL Runtime SDK is vendored
// and HAVE_MSAL_RUNTIME is defined (see windows/runner/README-aad-broker.md).
// It has not been executed against a live tenant in this PR; verification is
// manual on a school-account machine, per the project's live-testing policy.
// The completion guide documents the platform-thread marshalling the async
// callbacks require.
// ---------------------------------------------------------------------------
#include "aad_broker_msal.h"  // provides AcquireBrokeredToken(...)

static void HandleAcquire(bool interactive, HWND parent_window,
                          const BrokerRequest& req,
                          std::unique_ptr<flutter::MethodResult<>> result) {
  AcquireBrokeredToken(interactive, parent_window, req.client_id,
                       req.authority, req.scopes,
                       // on success:
                       [res = std::shared_ptr<flutter::MethodResult<>>(
                            std::move(result))](
                           const std::string& token, int64_t expires_on_ms,
                           const std::string& account) {
                         res->Success(TokenResult(token, expires_on_ms,
                                                  account));
                       },
                       // on failure:
                       [](const std::string& code, const std::string& message) {
                         // result already moved into the success closure; the
                         // MSAL bridge owns dispatching exactly one outcome.
                       });
}
#endif  // HAVE_MSAL_RUNTIME

void RegisterAadBroker(flutter::FlutterEngine* engine, HWND parent_window) {
  auto channel = std::make_shared<flutter::MethodChannel<>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [parent_window](const flutter::MethodCall<>& call,
                      std::unique_ptr<flutter::MethodResult<>> result) {
        const std::string& method = call.method_name();
        const bool is_silent = method == "acquireSilent";
        const bool is_interactive = method == "acquireInteractive";
        if (!is_silent && !is_interactive) {
          result->NotImplemented();
          return;
        }

        BrokerRequest req;
        if (!ParseRequest(call.arguments(), &req)) {
          result->Error("bad_args",
                        "expected {clientId, authority, scopes[]}");
          return;
        }

#ifdef HAVE_MSAL_RUNTIME
        HandleAcquire(is_interactive, parent_window, req, std::move(result));
#else
        // The WAM broker (MSAL Runtime) is not built into this binary. The Dart
        // layer treats this code as "broker unavailable" and surfaces a clear
        // message; see README-aad-broker.md to enable the real implementation.
        (void)parent_window;
        result->Error(
            "broker_unavailable",
            "Windows token broker (MSAL Runtime) is not built into this "
            "binary. See windows/runner/README-aad-broker.md.");
#endif
      });

  // Keep the channel alive for the lifetime of the engine.
  static std::shared_ptr<flutter::MethodChannel<>> s_channel;
  s_channel = std::move(channel);
}
