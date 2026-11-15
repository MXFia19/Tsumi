import CDiscord
import Foundation

// Swift layer over the C API of the Discord Social SDK (cdiscord.h, imported through Vendor/CDiscord). This is
// the only file that imports CDiscord. Memory rules are the ones of the SDK's C++ wrapper (discordpp.h):
// - strings returned by the SDK (out parameters and callback arguments) are copied, then freed with Discord_Free;
// - a Discord_ClientResult handed to a callback belongs to the callback (Discord_ClientResult_Drop);
// - every struct filled by *_Init or returned through an out parameter is released with *_Drop;
// - setters copy what they are given, so the strings passed in only need to live during the call.
// Callbacks are C function pointers: closures that capture nothing, the context travels in `userData` as a
// retained DiscordCallbackBox, released by the SDK through the `userDataFree` function. They only run inside
// Discord_RunCallbacks, which DiscordPresence calls from a main thread timer.

/// Status of the SDK connection (Discord_Client_Status).
enum DiscordClientStatus {
  case disconnected
  case connecting
  case connected
  case ready
  case reconnecting
  case disconnecting
  case httpWait
}

/// Outcome of an SDK call (Discord_ClientResult, already released).
struct DiscordResult {
  var successful: Bool
  var message: String
  /// The token or the authorization was refused (not a network problem): the account must be linked again.
  var isAuthorizationFailure: Bool
  /// The user cancelled (Discord_ErrorType_Aborted).
  var isAborted: Bool
  var isRetryable: Bool
}

/// Tokens of Client::GetToken / Client::RefreshToken.
struct DiscordTokens {
  var accessToken: String
  var refreshToken: String
  /// Seconds until the access token expires (7 days).
  var expiresIn: Int
}

/// A rich presence: the Discord_Activity fields Tsumi sets.
struct DiscordActivityContent: Equatable {
  struct Button: Equatable {
    var label: String
    var url: String
  }

  var details: String
  var state: String
  /// Asset key of the Discord application (`icon`) or an image URL (ActivityAssets accepts both).
  var largeImage: String
  var largeText: String?
  var start: Date?
  var end: Date?
  var partyId: String?
  var partySize: Int?
  var partyMax: Int?
  var buttons: [Button] = []

  /// Same presence: every field equal and the timestamps within `tolerance` seconds. Timestamps are recomputed
  /// from the player position on every check, so only a seek or a stall moves them that far.
  func matches(_ other: DiscordActivityContent, tolerance: TimeInterval) -> Bool {
    details == other.details
      && state == other.state
      && largeImage == other.largeImage
      && largeText == other.largeText
      && partyId == other.partyId
      && partySize == other.partySize
      && partyMax == other.partyMax
      && buttons == other.buttons
      && Self.close(start, other.start, tolerance)
      && Self.close(end, other.end, tolerance)
  }

  private static func close(_ first: Date?, _ second: Date?, _ tolerance: TimeInterval) -> Bool {
    switch (first, second) {
    case (nil, nil):
      return true
    case let (first?, second?):
      return abs(first.timeIntervalSince(second)) <= tolerance
    default:
      return false
    }
  }
}

/// The SDK client (Discord_Client). Created once and kept for the life of the app; only used from the main
/// thread (DiscordPresence). Not actor-isolated on purpose: the C callback closures formed here must not
/// inherit an actor isolation (a C function pointer cannot carry one).
final class DiscordSDKClient {
  let applicationId: UInt64
  private let client: UnsafeMutablePointer<Discord_Client>

  init(applicationId: UInt64) {
    let pointer = UnsafeMutablePointer<Discord_Client>.allocate(capacity: 1)
    pointer.initialize(to: Discord_Client())
    Discord_Client_Init(pointer)
    self.applicationId = applicationId
    self.client = pointer
    Discord_Client_SetApplicationId(pointer, applicationId)
    // The app manages its AVAudioSession (the player); the SDK would only touch it for voice calls.
    Discord_Client_SetEngineManagedAudioSession(pointer, true)
  }

  /// Runs the pending SDK callbacks on the calling thread (discordpp::RunCallbacks).
  static func runCallbacks() {
    Discord_RunCallbacks()
  }

  /// `openid sdk.social_layer_presence` (Client::GetDefaultPresenceScopes).
  static var defaultPresenceScopes: String {
    var value = Discord_String()
    Discord_Client_GetDefaultPresenceScopes(&value)
    return DiscordStrings.take(value)
  }

  var status: DiscordClientStatus {
    DiscordCallbacks.clientStatus(Discord_Client_GetStatus(client))
  }

  /// Username of the connected account (Client::GetCurrentUserV2), nil before Ready.
  var currentUsername: String? {
    var user = Discord_UserHandle()
    guard Discord_Client_GetCurrentUserV2(client, &user) else { return nil }
    var name = Discord_String()
    Discord_UserHandle_Username(&user, &name)
    let username = DiscordStrings.take(name)
    Discord_UserHandle_Drop(&user)
    return username.isEmpty ? nil : username
  }

  // MARK: - Callbacks

  /// SDK warnings and errors, to the device log.
  func addLogHandler() {
    Discord_Client_AddLogCallback(
      client,
      { message, severity, userData in
        DiscordCallbacks.log(message, severity, userData)
      },
      { userData in
        DiscordCallbacks.release(userData)
      },
      nil,
      Discord_LoggingSeverity_Warning
    )
  }

  /// Client::SetStatusChangedCallback; the error text is set when the status change comes from an error.
  func setStatusHandler(_ handler: @escaping @MainActor (DiscordClientStatus, String?) -> Void) {
    let box = DiscordCallbacks.retain(DiscordStatusBox(handler))
    Discord_Client_SetStatusChangedCallback(
      client,
      { status, error, errorDetail, userData in
        DiscordCallbacks.status(status, error, errorDetail, userData)
      },
      { userData in
        DiscordCallbacks.release(userData)
      },
      box
    )
  }

  /// Client::SetTokenExpirationCallback: the access token is about to expire (refresh, then UpdateToken).
  func setTokenExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
    let box = DiscordCallbacks.retain(DiscordSignalBox(handler))
    Discord_Client_SetTokenExpirationCallback(
      client,
      { userData in
        DiscordCallbacks.signal(userData)
      },
      { userData in
        DiscordCallbacks.release(userData)
      },
      box
    )
  }

  // MARK: - Authentication

  /// Client::Authorize with a PKCE challenge (Client::CreateAuthorizationCodeVerifier) and the default presence
  /// scopes. Opens the Discord app when installed, else a web authentication session; the redirect is
  /// `discord-<app id>:/authorize/callback`, handled by the SDK itself. The handler gets the code, the redirect
  /// URI and the code verifier to pass to `getToken`.
  func authorize(_ handler: @escaping @MainActor (DiscordResult, String, String, String) -> Void) {
    var verifier = Discord_AuthorizationCodeVerifier()
    Discord_Client_CreateAuthorizationCodeVerifier(client, &verifier)
    var challenge = Discord_AuthorizationCodeChallenge()
    Discord_AuthorizationCodeVerifier_Challenge(&verifier, &challenge)
    var verifierValue = Discord_String()
    Discord_AuthorizationCodeVerifier_Verifier(&verifier, &verifierValue)
    let verifierText = DiscordStrings.take(verifierValue)
    Discord_AuthorizationCodeVerifier_Drop(&verifier)

    var args = Discord_AuthorizationArgs()
    Discord_AuthorizationArgs_Init(&args)
    Discord_AuthorizationArgs_SetClientId(&args, applicationId)
    DiscordStrings.with(Self.defaultPresenceScopes) { scopes in
      Discord_AuthorizationArgs_SetScopes(&args, scopes)
    }
    Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)
    Discord_AuthorizationCodeChallenge_Drop(&challenge)

    let box = DiscordCallbacks.retain(DiscordAuthorizationBox { result, code, redirectUri in
      handler(result, code, redirectUri, verifierText)
    })
    Discord_Client_Authorize(
      client,
      &args,
      { result, code, redirectUri, userData in
        DiscordCallbacks.authorization(result, code, redirectUri, userData)
      },
      { userData in
        DiscordCallbacks.release(userData)
      },
      box
    )
    Discord_AuthorizationArgs_Drop(&args)
  }

  /// Client::AbortAuthorize.
  func abortAuthorize() {
    Discord_Client_AbortAuthorize(client)
  }

  /// Client::GetToken (public client, PKCE): code → access + refresh tokens. Tokens are nil on failure.
  func getToken(code: String, verifier: String, redirectUri: String, _ handler: @escaping @MainActor (DiscordResult, DiscordTokens?) -> Void) {
    let box = DiscordCallbacks.retain(DiscordTokenBox(handler))
    let client = self.client
    let applicationId = self.applicationId
    DiscordStrings.with(code) { codeValue in
      DiscordStrings.with(verifier) { verifierValue in
        DiscordStrings.with(redirectUri) { redirectValue in
          Discord_Client_GetToken(
            client,
            applicationId,
            codeValue,
            verifierValue,
            redirectValue,
            { result, accessToken, refreshToken, _, expiresIn, scopes, userData in
              DiscordCallbacks.tokens(result, accessToken, refreshToken, expiresIn, scopes, userData)
            },
            { userData in
              DiscordCallbacks.release(userData)
            },
            box
          )
        }
      }
    }
  }

  /// Client::RefreshToken: new access + refresh tokens (both old ones stop working). Tokens are nil on failure.
  func refreshToken(_ refreshToken: String, _ handler: @escaping @MainActor (DiscordResult, DiscordTokens?) -> Void) {
    let box = DiscordCallbacks.retain(DiscordTokenBox(handler))
    let client = self.client
    let applicationId = self.applicationId
    DiscordStrings.with(refreshToken) { tokenValue in
      Discord_Client_RefreshToken(
        client,
        applicationId,
        tokenValue,
        { result, accessToken, refreshToken, _, expiresIn, scopes, userData in
          DiscordCallbacks.tokens(result, accessToken, refreshToken, expiresIn, scopes, userData)
        },
        { userData in
          DiscordCallbacks.release(userData)
        },
        box
      )
    }
  }

  /// Client::UpdateToken (Bearer). Call `connect()` once it succeeded.
  func updateToken(_ accessToken: String, _ handler: @escaping @MainActor (DiscordResult) -> Void) {
    let box = DiscordCallbacks.retain(DiscordResultBox(handler))
    let client = self.client
    DiscordStrings.with(accessToken) { tokenValue in
      Discord_Client_UpdateToken(
        client,
        Discord_AuthorizationTokenType_Bearer,
        tokenValue,
        { result, userData in
          DiscordCallbacks.result(result, userData)
        },
        { userData in
          DiscordCallbacks.release(userData)
        },
        box
      )
    }
  }

  /// Client::RevokeToken: every token of this user for the application stops working.
  func revokeToken(_ token: String) {
    let box = DiscordCallbacks.retain(DiscordResultBox { result in
      if !result.successful {
        NSLog("[Discord] RevokeToken failed: %@", result.message)
      }
    })
    let client = self.client
    let applicationId = self.applicationId
    DiscordStrings.with(token) { tokenValue in
      Discord_Client_RevokeToken(
        client,
        applicationId,
        tokenValue,
        { result, userData in
          DiscordCallbacks.result(result, userData)
        },
        { userData in
          DiscordCallbacks.release(userData)
        },
        box
      )
    }
  }

  // MARK: - Connection

  func connect() {
    Discord_Client_Connect(client)
  }

  func disconnect() {
    Discord_Client_Disconnect(client)
  }

  // MARK: - Rich presence

  func clearRichPresence() {
    Discord_Client_ClearRichPresence(client)
  }

  /// Client::UpdateRichPresence with a Watching activity. Timestamps go in milliseconds since the epoch.
  func updateRichPresence(_ content: DiscordActivityContent, _ handler: @escaping @MainActor (DiscordResult) -> Void) {
    var activity = Discord_Activity()
    Discord_Activity_Init(&activity)
    Discord_Activity_SetType(&activity, Discord_ActivityTypes_Watching)
    DiscordStrings.withPointer(content.details) { value in
      Discord_Activity_SetDetails(&activity, value)
    }
    DiscordStrings.withPointer(content.state) { value in
      Discord_Activity_SetState(&activity, value)
    }

    var assets = Discord_ActivityAssets()
    Discord_ActivityAssets_Init(&assets)
    DiscordStrings.withPointer(content.largeImage) { value in
      Discord_ActivityAssets_SetLargeImage(&assets, value)
    }
    if let largeText = content.largeText {
      DiscordStrings.withPointer(largeText) { value in
        Discord_ActivityAssets_SetLargeText(&assets, value)
      }
    }
    Discord_Activity_SetAssets(&activity, &assets)
    Discord_ActivityAssets_Drop(&assets)

    if content.start != nil || content.end != nil {
      var timestamps = Discord_ActivityTimestamps()
      Discord_ActivityTimestamps_Init(&timestamps)
      if let start = content.start {
        Discord_ActivityTimestamps_SetStart(&timestamps, Self.milliseconds(start))
      }
      if let end = content.end {
        Discord_ActivityTimestamps_SetEnd(&timestamps, Self.milliseconds(end))
      }
      Discord_Activity_SetTimestamps(&activity, &timestamps)
      Discord_ActivityTimestamps_Drop(&timestamps)
    }

    if let size = content.partySize, let max = content.partyMax {
      var party = Discord_ActivityParty()
      Discord_ActivityParty_Init(&party)
      if let partyId = content.partyId {
        DiscordStrings.with(partyId) { value in
          Discord_ActivityParty_SetId(&party, value)
        }
      }
      Discord_ActivityParty_SetCurrentSize(&party, Int32(clamping: size))
      Discord_ActivityParty_SetMaxSize(&party, Int32(clamping: max))
      Discord_Activity_SetParty(&activity, &party)
      Discord_ActivityParty_Drop(&party)
    }

    for item in content.buttons.prefix(2) {
      var button = Discord_ActivityButton()
      Discord_ActivityButton_Init(&button)
      DiscordStrings.with(item.label) { value in
        Discord_ActivityButton_SetLabel(&button, value)
      }
      DiscordStrings.with(item.url) { value in
        Discord_ActivityButton_SetUrl(&button, value)
      }
      Discord_Activity_AddButton(&activity, &button)
      Discord_ActivityButton_Drop(&button)
    }

    let box = DiscordCallbacks.retain(DiscordResultBox(handler))
    Discord_Client_UpdateRichPresence(
      client,
      &activity,
      { result, userData in
        DiscordCallbacks.result(result, userData)
      },
      { userData in
        DiscordCallbacks.release(userData)
      },
      box
    )
    Discord_Activity_Drop(&activity)
  }

  private static func milliseconds(_ date: Date) -> UInt64 {
    let value = date.timeIntervalSince1970 * 1000
    guard value.isFinite, value > 0 else { return 0 }
    return UInt64(value)
  }
}

// MARK: - Strings

/// Discord_String (pointer + size, not NUL terminated) ↔ Swift String.
enum DiscordStrings {
  /// Copies a string the SDK returned and frees it with Discord_Free.
  static func take(_ value: Discord_String) -> String {
    guard let pointer = value.ptr else { return "" }
    let text = String(decoding: UnsafeBufferPointer(start: UnsafePointer(pointer), count: value.size), as: UTF8.self)
    Discord_Free(UnsafeMutableRawPointer(pointer))
    return text
  }

  /// Calls `body` with a Discord_String borrowing the UTF-8 bytes of `text`, valid during the call only
  /// (the SDK copies it). A NUL byte is kept after the text so the pointer is never nil.
  static func with(_ text: String, _ body: (Discord_String) -> Void) {
    var bytes = Array(text.utf8)
    let count = bytes.count
    bytes.append(0)
    bytes.withUnsafeMutableBufferPointer { buffer in
      body(Discord_String(ptr: buffer.baseAddress, size: count))
    }
  }

  /// Same, for the setters that take an optional string (`Discord_String*`).
  static func withPointer(_ text: String, _ body: (UnsafeMutablePointer<Discord_String>) -> Void) {
    with(text) { value in
      var copy = value
      withUnsafeMutablePointer(to: &copy) { pointer in
        body(pointer)
      }
    }
  }
}

// MARK: - Callback plumbing

/// `userData` of the C callbacks: retained while the SDK holds it, released by its `userDataFree` call.
class DiscordCallbackBox {}

final class DiscordResultBox: DiscordCallbackBox {
  let handler: @MainActor (DiscordResult) -> Void

  init(_ handler: @escaping @MainActor (DiscordResult) -> Void) {
    self.handler = handler
  }
}

final class DiscordTokenBox: DiscordCallbackBox {
  let handler: @MainActor (DiscordResult, DiscordTokens?) -> Void

  init(_ handler: @escaping @MainActor (DiscordResult, DiscordTokens?) -> Void) {
    self.handler = handler
  }
}

final class DiscordAuthorizationBox: DiscordCallbackBox {
  let handler: @MainActor (DiscordResult, String, String) -> Void

  init(_ handler: @escaping @MainActor (DiscordResult, String, String) -> Void) {
    self.handler = handler
  }
}

final class DiscordStatusBox: DiscordCallbackBox {
  let handler: @MainActor (DiscordClientStatus, String?) -> Void

  init(_ handler: @escaping @MainActor (DiscordClientStatus, String?) -> Void) {
    self.handler = handler
  }
}

final class DiscordSignalBox: DiscordCallbackBox {
  let handler: @MainActor () -> Void

  init(_ handler: @escaping @MainActor () -> Void) {
    self.handler = handler
  }
}

/// Bodies of the C callbacks. They copy and release the SDK values at once (on the calling thread), then run
/// the Swift handler on the main actor, on the next main-queue turn (never inside Discord_RunCallbacks).
enum DiscordCallbacks {
  static func retain(_ box: DiscordCallbackBox) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(box).toOpaque()
  }

  static func release(_ userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<DiscordCallbackBox>.fromOpaque(userData).release()
  }

  private static func box<Box: DiscordCallbackBox>(_ userData: UnsafeMutableRawPointer?, as type: Box.Type) -> Box? {
    guard let userData else { return nil }
    return Unmanaged<DiscordCallbackBox>.fromOpaque(userData).takeUnretainedValue() as? Box
  }

  /// Always after Discord_RunCallbacks has returned: calling the SDK again from inside one of its callbacks
  /// (UpdateRichPresence on Ready, UpdateToken after RefreshToken, Connect after UpdateToken...) corrupts the heap
  /// and crashes the app (reproduced with the Windows build of the same SDK). The values are already copied.
  private static func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        work()
      }
    }
  }

  static func result(_ result: UnsafeMutablePointer<Discord_ClientResult>?, _ userData: UnsafeMutableRawPointer?) {
    let value = consume(result)
    guard let handler = box(userData, as: DiscordResultBox.self)?.handler else { return }
    onMain {
      handler(value)
    }
  }

  static func tokens(
    _ result: UnsafeMutablePointer<Discord_ClientResult>?,
    _ accessToken: Discord_String,
    _ refreshToken: Discord_String,
    _ expiresIn: Int32,
    _ scopes: Discord_String,
    _ userData: UnsafeMutableRawPointer?
  ) {
    let value = consume(result)
    let access = DiscordStrings.take(accessToken)
    let refresh = DiscordStrings.take(refreshToken)
    _ = DiscordStrings.take(scopes)
    let tokens: DiscordTokens? = value.successful && !access.isEmpty
      ? DiscordTokens(accessToken: access, refreshToken: refresh, expiresIn: Int(expiresIn))
      : nil
    guard let handler = box(userData, as: DiscordTokenBox.self)?.handler else { return }
    onMain {
      handler(value, tokens)
    }
  }

  static func authorization(
    _ result: UnsafeMutablePointer<Discord_ClientResult>?,
    _ code: Discord_String,
    _ redirectUri: Discord_String,
    _ userData: UnsafeMutableRawPointer?
  ) {
    let value = consume(result)
    let codeText = DiscordStrings.take(code)
    let redirectText = DiscordStrings.take(redirectUri)
    guard let handler = box(userData, as: DiscordAuthorizationBox.self)?.handler else { return }
    onMain {
      handler(value, codeText, redirectText)
    }
  }

  static func status(_ status: Discord_Client_Status, _ error: Discord_Client_Error, _ errorDetail: Int32, _ userData: UnsafeMutableRawPointer?) {
    let mapped = clientStatus(status)
    var message: String?
    if error != Discord_Client_Error_None {
      var text = Discord_String()
      Discord_Client_ErrorToString(error, &text)
      let name = DiscordStrings.take(text)
      message = errorDetail != 0 ? "\(name) (\(errorDetail))" : name
    }
    guard let handler = box(userData, as: DiscordStatusBox.self)?.handler else { return }
    let errorText = message
    onMain {
      handler(mapped, errorText)
    }
  }

  static func signal(_ userData: UnsafeMutableRawPointer?) {
    guard let handler = box(userData, as: DiscordSignalBox.self)?.handler else { return }
    onMain {
      handler()
    }
  }

  static func log(_ message: Discord_String, _ severity: Discord_LoggingSeverity, _ userData: UnsafeMutableRawPointer?) {
    let text = DiscordStrings.take(message)
    let level = severity == Discord_LoggingSeverity_Error ? "error" : "warning"
    NSLog("[Discord SDK %@] %@", level, text)
  }

  static func clientStatus(_ status: Discord_Client_Status) -> DiscordClientStatus {
    if status == Discord_Client_Status_Ready { return .ready }
    if status == Discord_Client_Status_Connected { return .connected }
    if status == Discord_Client_Status_Connecting { return .connecting }
    if status == Discord_Client_Status_Reconnecting { return .reconnecting }
    if status == Discord_Client_Status_Disconnecting { return .disconnecting }
    if status == Discord_Client_Status_HttpWait { return .httpWait }
    return .disconnected
  }

  /// Reads a ClientResult handed to a callback, then releases it (the callback owns it, like discordpp).
  private static func consume(_ result: UnsafeMutablePointer<Discord_ClientResult>?) -> DiscordResult {
    guard let result else {
      return DiscordResult(successful: false, message: "No answer from Discord", isAuthorizationFailure: false, isAborted: false, isRetryable: false)
    }
    let successful = Discord_ClientResult_Successful(result)
    let retryable = Discord_ClientResult_Retryable(result)
    let type = Discord_ClientResult_Type(result)
    let status = Int(Discord_ClientResult_Status(result).rawValue)
    var error = Discord_String()
    Discord_ClientResult_Error(result, &error)
    let message = DiscordStrings.take(error)
    Discord_ClientResult_Drop(result)
    let refused = type == Discord_ErrorType_AuthorizationFailed || status == 400 || status == 401 || status == 403
    return DiscordResult(
      successful: successful,
      message: message.isEmpty ? (status > 0 ? "HTTP \(status)" : "unknown error") : message,
      isAuthorizationFailure: !successful && refused,
      isAborted: type == Discord_ErrorType_Aborted,
      isRetryable: retryable
    )
  }
}
