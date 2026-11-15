// Bindings for the Discord Social SDK C API (cdiscord.h), called through koffi.
// Only the client, account linking and rich presence functions used by Tsumi are declared.
// This file has no Electron import, so it can be loaded from plain Node to check the bindings.

/** @typedef {{ ok: boolean, type: number, status: number, retryable: boolean, error: string }} SdkResult */
/**
 * Texts already within the SDK limits (2 to 128 characters, image up to 300), timestamps in milliseconds.
 * @typedef {{ type: number, details?: string, state?: string, largeImage?: string, largeText?: string, start?: number, end?: number, party?: { id: string, current: number, max: number }, buttons?: { label: string, url: string }[] }} SdkActivity
 */

/** Discord_Client_Status */
export const ClientStatus = { Disconnected: 0, Connecting: 1, Connected: 2, Ready: 3, Reconnecting: 4, Disconnecting: 5, HttpWait: 6 }
/** Discord_ErrorType */
export const ErrorType = { None: 0, NetworkError: 1, HTTPError: 2, ClientNotReady: 3, Disabled: 4, ClientDestroyed: 5, ValidationError: 6, Aborted: 7, AuthorizationFailed: 8, RPCError: 9 }
/** Discord_ActivityTypes */
export const ActivityType = { Playing: 0, Streaming: 1, Listening: 2, Watching: 3, CustomStatus: 4, Competing: 5, HangStatus: 6 }

const TOKEN_TYPE_BEARER = 1 // Discord_AuthorizationTokenType_Bearer

/**
 * Loads the SDK library and declares its functions. Throws if koffi or the library can't be loaded.
 * @param {any} koffi the koffi module (passed in, so the caller decides how it is required)
 * @param {string} libraryPath path to discord_partner_sdk.dll
 */
export function loadDiscordSdk (koffi, libraryPath) {
  const lib = koffi.load(libraryPath)

  // Discord_String is {ptr, size}, not NUL-terminated. Strings the SDK returns (out parameters and callback
  // arguments) belong to the caller and are released with Discord_Free(ptr), like discordpp.h does.
  koffi.struct('Discord_String', { ptr: 'void *', size: 'size_t' })
  // Same layout, for strings given to the SDK: koffi passes a temporary UTF-8 copy of the JS string, which the
  // SDK copies during the call.
  koffi.struct('Discord_StringIn', { ptr: 'const char *', size: 'size_t' })
  // Every SDK object (Discord_Client, Discord_Activity...) is a struct holding a single opaque pointer, which the
  // caller allocates and the SDK fills (_Init or return value) and releases (_Drop).
  const Opaque = koffi.struct('Discord_Opaque', { opaque: 'void *' })

  const FreeFn = koffi.pointer(koffi.proto('void Discord_FreeFn(void *userData)'))
  const StatusCallback = koffi.pointer(koffi.proto('void Discord_Client_OnStatusChanged(int status, int error, int32_t errorDetail, void *userData)'))
  const AuthorizationCallback = koffi.pointer(koffi.proto('void Discord_Client_AuthorizationCallback(void *result, Discord_String code, Discord_String redirectUri, void *userData)'))
  const TokenExchangeCallback = koffi.pointer(koffi.proto('void Discord_Client_TokenExchangeCallback(void *result, Discord_String accessToken, Discord_String refreshToken, int tokenType, int32_t expiresIn, Discord_String scopes, void *userData)'))
  // UpdateToken, RevokeToken and UpdateRichPresence callbacks all have this shape.
  const ResultCallback = koffi.pointer(koffi.proto('void Discord_Client_ResultCallback(void *result, void *userData)'))
  const TokenExpirationCallback = koffi.pointer(koffi.proto('void Discord_Client_TokenExpirationCallback(void *userData)'))

  const f = {
    Free: lib.func('void Discord_Free(void *ptr)'),
    RunCallbacks: lib.func('void Discord_RunCallbacks()'),

    ClientResult_Drop: lib.func('void Discord_ClientResult_Drop(void *self)'),
    ClientResult_Successful: lib.func('bool Discord_ClientResult_Successful(void *self)'),
    ClientResult_Retryable: lib.func('bool Discord_ClientResult_Retryable(void *self)'),
    ClientResult_Type: lib.func('int Discord_ClientResult_Type(void *self)'),
    ClientResult_Status: lib.func('int Discord_ClientResult_Status(void *self)'),
    ClientResult_ToString: lib.func('void Discord_ClientResult_ToString(void *self, _Out_ Discord_String *returnValue)'),

    Client_Init: lib.func('void Discord_Client_Init(void *self)'),
    Client_Drop: lib.func('void Discord_Client_Drop(void *self)'),
    Client_SetApplicationId: lib.func('void Discord_Client_SetApplicationId(void *self, uint64_t applicationId)'),
    Client_GetApplicationId: lib.func('uint64_t Discord_Client_GetApplicationId(void *self)'),
    Client_GetStatus: lib.func('int Discord_Client_GetStatus(void *self)'),
    Client_StatusToString: lib.func('void Discord_Client_StatusToString(int type, _Out_ Discord_String *returnValue)'),
    Client_ErrorToString: lib.func('void Discord_Client_ErrorToString(int type, _Out_ Discord_String *returnValue)'),
    Client_GetDefaultPresenceScopes: lib.func('void Discord_Client_GetDefaultPresenceScopes(_Out_ Discord_String *returnValue)'),
    Client_GetVersionMajor: lib.func('int32_t Discord_Client_GetVersionMajor()'),
    Client_GetVersionMinor: lib.func('int32_t Discord_Client_GetVersionMinor()'),
    Client_GetVersionPatch: lib.func('int32_t Discord_Client_GetVersionPatch()'),
    Client_SetStatusChangedCallback: lib.func('void Discord_Client_SetStatusChangedCallback(void *self, Discord_Client_OnStatusChanged *cb, Discord_FreeFn *cb__userDataFree, void *cb__userData)'),
    Client_SetTokenExpirationCallback: lib.func('void Discord_Client_SetTokenExpirationCallback(void *self, Discord_Client_TokenExpirationCallback *callback, Discord_FreeFn *callback__userDataFree, void *callback__userData)'),
    Client_Connect: lib.func('void Discord_Client_Connect(void *self)'),
    Client_Disconnect: lib.func('void Discord_Client_Disconnect(void *self)'),

    Client_CreateAuthorizationCodeVerifier: lib.func('void Discord_Client_CreateAuthorizationCodeVerifier(void *self, void *returnValue)'),
    AuthorizationCodeVerifier_Drop: lib.func('void Discord_AuthorizationCodeVerifier_Drop(void *self)'),
    AuthorizationCodeVerifier_Challenge: lib.func('void Discord_AuthorizationCodeVerifier_Challenge(void *self, void *returnValue)'),
    AuthorizationCodeVerifier_Verifier: lib.func('void Discord_AuthorizationCodeVerifier_Verifier(void *self, _Out_ Discord_String *returnValue)'),
    AuthorizationCodeChallenge_Drop: lib.func('void Discord_AuthorizationCodeChallenge_Drop(void *self)'),
    AuthorizationArgs_Init: lib.func('void Discord_AuthorizationArgs_Init(void *self)'),
    AuthorizationArgs_Drop: lib.func('void Discord_AuthorizationArgs_Drop(void *self)'),
    AuthorizationArgs_SetClientId: lib.func('void Discord_AuthorizationArgs_SetClientId(void *self, uint64_t value)'),
    AuthorizationArgs_SetScopes: lib.func('void Discord_AuthorizationArgs_SetScopes(void *self, Discord_StringIn value)'),
    AuthorizationArgs_SetCodeChallenge: lib.func('void Discord_AuthorizationArgs_SetCodeChallenge(void *self, void *value)'),
    Client_Authorize: lib.func('void Discord_Client_Authorize(void *self, void *args, Discord_Client_AuthorizationCallback *callback, Discord_FreeFn *callback__userDataFree, void *callback__userData)'),
    Client_AbortAuthorize: lib.func('void Discord_Client_AbortAuthorize(void *self)'),
    Client_GetToken: lib.func('void Discord_Client_GetToken(void *self, uint64_t applicationId, Discord_StringIn code, Discord_StringIn codeVerifier, Discord_StringIn redirectUri, Discord_Client_TokenExchangeCallback *callback, Discord_FreeFn *callback__userDataFree, void *callback__userData)'),
    Client_RefreshToken: lib.func('void Discord_Client_RefreshToken(void *self, uint64_t applicationId, Discord_StringIn refreshToken, Discord_Client_TokenExchangeCallback *callback, Discord_FreeFn *callback__userDataFree, void *callback__userData)'),
    Client_RevokeToken: lib.func('void Discord_Client_RevokeToken(void *self, uint64_t applicationId, Discord_StringIn token, Discord_Client_ResultCallback *callback, Discord_FreeFn *callback__userDataFree, void *callback__userData)'),
    Client_UpdateToken: lib.func('void Discord_Client_UpdateToken(void *self, int tokenType, Discord_StringIn token, Discord_Client_ResultCallback *callback, Discord_FreeFn *callback__userDataFree, void *callback__userData)'),

    Client_GetCurrentUserV2: lib.func('bool Discord_Client_GetCurrentUserV2(void *self, void *returnValue)'),
    UserHandle_Drop: lib.func('void Discord_UserHandle_Drop(void *self)'),
    UserHandle_DisplayName: lib.func('void Discord_UserHandle_DisplayName(void *self, _Out_ Discord_String *returnValue)'),

    Activity_Init: lib.func('void Discord_Activity_Init(void *self)'),
    Activity_Drop: lib.func('void Discord_Activity_Drop(void *self)'),
    Activity_SetType: lib.func('void Discord_Activity_SetType(void *self, int value)'),
    Activity_SetDetails: lib.func('void Discord_Activity_SetDetails(void *self, Discord_StringIn *value)'),
    Activity_SetState: lib.func('void Discord_Activity_SetState(void *self, Discord_StringIn *value)'),
    Activity_SetAssets: lib.func('void Discord_Activity_SetAssets(void *self, void *value)'),
    Activity_SetTimestamps: lib.func('void Discord_Activity_SetTimestamps(void *self, void *value)'),
    Activity_SetParty: lib.func('void Discord_Activity_SetParty(void *self, void *value)'),
    Activity_AddButton: lib.func('void Discord_Activity_AddButton(void *self, void *button)'),
    ActivityAssets_Init: lib.func('void Discord_ActivityAssets_Init(void *self)'),
    ActivityAssets_Drop: lib.func('void Discord_ActivityAssets_Drop(void *self)'),
    ActivityAssets_SetLargeImage: lib.func('void Discord_ActivityAssets_SetLargeImage(void *self, Discord_StringIn *value)'),
    ActivityAssets_SetLargeText: lib.func('void Discord_ActivityAssets_SetLargeText(void *self, Discord_StringIn *value)'),
    ActivityTimestamps_Init: lib.func('void Discord_ActivityTimestamps_Init(void *self)'),
    ActivityTimestamps_Drop: lib.func('void Discord_ActivityTimestamps_Drop(void *self)'),
    ActivityTimestamps_SetStart: lib.func('void Discord_ActivityTimestamps_SetStart(void *self, uint64_t value)'),
    ActivityTimestamps_SetEnd: lib.func('void Discord_ActivityTimestamps_SetEnd(void *self, uint64_t value)'),
    ActivityParty_Init: lib.func('void Discord_ActivityParty_Init(void *self)'),
    ActivityParty_Drop: lib.func('void Discord_ActivityParty_Drop(void *self)'),
    ActivityParty_SetId: lib.func('void Discord_ActivityParty_SetId(void *self, Discord_StringIn value)'),
    ActivityParty_SetCurrentSize: lib.func('void Discord_ActivityParty_SetCurrentSize(void *self, int32_t value)'),
    ActivityParty_SetMaxSize: lib.func('void Discord_ActivityParty_SetMaxSize(void *self, int32_t value)'),
    ActivityButton_Init: lib.func('void Discord_ActivityButton_Init(void *self)'),
    ActivityButton_Drop: lib.func('void Discord_ActivityButton_Drop(void *self)'),
    ActivityButton_SetLabel: lib.func('void Discord_ActivityButton_SetLabel(void *self, Discord_StringIn value)'),
    ActivityButton_SetUrl: lib.func('void Discord_ActivityButton_SetUrl(void *self, Discord_StringIn value)'),
    Client_UpdateRichPresence: lib.func('void Discord_Client_UpdateRichPresence(void *self, void *activity, Discord_Client_ResultCallback *cb, Discord_FreeFn *cb__userDataFree, void *cb__userData)'),
    Client_ClearRichPresence: lib.func('void Discord_Client_ClearRichPresence(void *self)')
  }

  /** @param {string} value */
  const str = value => ({ ptr: value, size: Buffer.byteLength(value, 'utf8') })

  /**
   * Reads a Discord_String returned by the SDK and frees it.
   * @param {{ ptr?: any, size?: number | bigint }} value
   */
  function take (value) {
    if (!value?.ptr) return ''
    const size = Number(value.size)
    const text = size > 0 ? koffi.decode.string(value.ptr, size) : ''
    f.Free(value.ptr)
    return text
  }

  /** @param {(out: any) => void} call */
  function outString (call) {
    const out = {}
    call(out)
    return take(out)
  }

  /**
   * Allocates an SDK object, runs `use`, then drops and frees it. The SDK copies what it keeps (setters, calls).
   * @template T
   * @param {((self: any) => void) | null} init null when `use` fills the object (return value parameter)
   * @param {(self: any) => void} drop
   * @param {(self: any) => T} use
   * @returns {T}
   */
  function scoped (init, drop, use) {
    const self = koffi.alloc(Opaque, 1)
    koffi.encode(self, Opaque, { opaque: null })
    try {
      if (init) init(self)
      return use(self)
    } finally {
      if (koffi.decode(self, Opaque).opaque) drop(self)
      koffi.free(self)
    }
  }

  // Callbacks are registered with koffi and passed with the SDK's Discord_FreeFn and a userData id. The SDK calls the
  // free function once it no longer needs a callback (after a one-shot callback ran, when a callback is replaced, or
  // when the client is dropped): that is when the koffi registration is released.
  /** @type {Map<number, any>} */
  const registered = new Map()
  let nextId = 1
  const freeUserData = koffi.register((/** @type {any} */ userData) => {
    const id = Number(userData)
    const callback = registered.get(id)
    if (callback == null) return
    registered.delete(id)
    // Not from inside the free function: the SDK may free a callback while it is still running it.
    setImmediate(() => koffi.unregister(callback))
  }, FreeFn)

  /**
   * @param {any} type pointer to a callback prototype
   * @param {Function} fn
   * @returns {[any, any, bigint]} callback, free function and userData arguments
   */
  function callback (type, fn) {
    const id = nextId++
    const cb = koffi.register((/** @type {any[]} */ ...args) => {
      try {
        fn(...args)
      } catch (error) {
        console.error('Discord SDK callback failed:', error)
      }
    }, type)
    registered.set(id, cb)
    return [cb, freeUserData, BigInt(id)]
  }

  /**
   * Reads a Discord_ClientResult given to a callback and drops it (callbacks own their result, see discordpp.h).
   * @param {any} result
   * @returns {SdkResult}
   */
  function readResult (result) {
    if (!result) return { ok: false, type: -1, status: 0, retryable: false, error: 'No result' }
    try {
      const ok = f.ClientResult_Successful(result)
      return {
        ok,
        type: f.ClientResult_Type(result),
        status: f.ClientResult_Status(result),
        retryable: f.ClientResult_Retryable(result),
        error: ok ? '' : outString(out => f.ClientResult_ToString(result, out))
      }
    } finally {
      f.ClientResult_Drop(result)
    }
  }

  /** @param {SdkResult} result */
  function toError (result) {
    return Object.assign(new Error(result.error || 'Discord SDK error'), { result })
  }

  /**
   * Text that is optional in the SDK: null leaves it unset.
   * @param {string | undefined} value
   */
  const optional = value => value ? str(value) : null

  /**
   * Builds a Discord_Activity, gives it to `use`, then drops it (UpdateRichPresence copies it).
   * @template T
   * @param {SdkActivity} activity
   * @param {(act: any) => T} use
   * @returns {T}
   */
  function withActivity (activity, use) {
    return scoped(f.Activity_Init, f.Activity_Drop, act => {
      f.Activity_SetType(act, activity.type)
      f.Activity_SetDetails(act, optional(activity.details))
      f.Activity_SetState(act, optional(activity.state))
      if (activity.largeImage || activity.largeText) {
        scoped(f.ActivityAssets_Init, f.ActivityAssets_Drop, assets => {
          f.ActivityAssets_SetLargeImage(assets, optional(activity.largeImage))
          f.ActivityAssets_SetLargeText(assets, optional(activity.largeText))
          f.Activity_SetAssets(act, assets)
        })
      }
      if (activity.start || activity.end) {
        scoped(f.ActivityTimestamps_Init, f.ActivityTimestamps_Drop, timestamps => {
          if (activity.start) f.ActivityTimestamps_SetStart(timestamps, activity.start)
          if (activity.end) f.ActivityTimestamps_SetEnd(timestamps, activity.end)
          f.Activity_SetTimestamps(act, timestamps)
        })
      }
      const party = activity.party
      if (party) {
        scoped(f.ActivityParty_Init, f.ActivityParty_Drop, partyObject => {
          f.ActivityParty_SetId(partyObject, str(party.id))
          f.ActivityParty_SetCurrentSize(partyObject, party.current)
          f.ActivityParty_SetMaxSize(partyObject, party.max)
          f.Activity_SetParty(act, partyObject)
        })
      }
      for (const button of activity.buttons || []) {
        scoped(f.ActivityButton_Init, f.ActivityButton_Drop, buttonObject => {
          f.ActivityButton_SetLabel(buttonObject, str(button.label))
          f.ActivityButton_SetUrl(buttonObject, str(button.url))
          f.Activity_AddButton(act, buttonObject)
        })
      }
      return use(act)
    })
  }

  /** @param {bigint} applicationId */
  function createClient (applicationId) {
    const self = koffi.alloc(Opaque, 1)
    f.Client_Init(self)
    f.Client_SetApplicationId(self, applicationId)
    let dropped = false

    /**
     * Calls a function taking a Discord_Client_TokenExchangeCallback.
     * @param {(callbackArgs: [any, any, bigint]) => void} call
     * @returns {Promise<{ accessToken: string, refreshToken: string, expiresIn: number, scopes: string }>}
     */
    const tokenExchange = call => new Promise((resolve, reject) => {
      call(callback(TokenExchangeCallback, (/** @type {any} */ result, /** @type {any} */ accessToken, /** @type {any} */ refreshToken, /** @type {number} */ tokenType, /** @type {number} */ expiresIn, /** @type {any} */ scopes) => {
        const res = readResult(result)
        const tokens = { accessToken: take(accessToken), refreshToken: take(refreshToken), expiresIn, scopes: take(scopes) }
        if (res.ok) resolve(tokens)
        else reject(toError(res))
      }))
    })

    /**
     * Calls a function taking a callback that only receives a Discord_ClientResult.
     * @param {(callbackArgs: [any, any, bigint]) => void} call
     * @returns {Promise<void>}
     */
    const resultCall = call => new Promise((resolve, reject) => {
      call(callback(ResultCallback, (/** @type {any} */ result) => {
        const res = readResult(result)
        if (res.ok) resolve(undefined)
        else reject(toError(res))
      }))
    })

    return {
      applicationId: () => f.Client_GetApplicationId(self),
      /** @returns {number} Discord_Client_Status */
      status: () => f.Client_GetStatus(self),
      // Listeners run after Discord_RunCallbacks has returned: calling the SDK again from inside one of its
      // callbacks (UpdateRichPresence on Ready, RefreshToken on expiry...) corrupts the heap and crashes the app.
      /** @param {(status: number, error: number, errorDetail: number) => void} fn */
      onStatusChanged (fn) {
        f.Client_SetStatusChangedCallback(self, ...callback(StatusCallback, (/** @type {number} */ status, /** @type {number} */ error, /** @type {number} */ errorDetail) => {
          setImmediate(() => fn(status, error, errorDetail))
        }))
      },
      /** Called before the access token expires. @param {() => void} fn */
      onTokenExpiration (fn) {
        f.Client_SetTokenExpirationCallback(self, ...callback(TokenExpirationCallback, () => { setImmediate(() => fn()) }))
      },
      connect: () => f.Client_Connect(self),
      disconnect: () => f.Client_Disconnect(self),

      /**
       * OAuth2 authorization with PKCE: the SDK shows the Discord prompt (in the Discord app, or in the browser with
       * a loopback server for http://127.0.0.1/callback).
       * @param {string} scopes
       * @returns {Promise<{ code: string, redirectUri: string, verifier: string }>}
       */
      authorize: scopes => new Promise((resolve, reject) => {
        scoped(null, f.AuthorizationCodeVerifier_Drop, verifierObject => {
          f.Client_CreateAuthorizationCodeVerifier(self, verifierObject)
          const verifier = outString(out => f.AuthorizationCodeVerifier_Verifier(verifierObject, out))
          scoped(null, f.AuthorizationCodeChallenge_Drop, challenge => {
            f.AuthorizationCodeVerifier_Challenge(verifierObject, challenge)
            scoped(f.AuthorizationArgs_Init, f.AuthorizationArgs_Drop, args => {
              f.AuthorizationArgs_SetClientId(args, applicationId)
              f.AuthorizationArgs_SetScopes(args, str(scopes))
              f.AuthorizationArgs_SetCodeChallenge(args, challenge)
              f.Client_Authorize(self, args, ...callback(AuthorizationCallback, (/** @type {any} */ result, /** @type {any} */ code, /** @type {any} */ redirectUri) => {
                const res = readResult(result)
                const codeText = take(code)
                const redirectText = take(redirectUri)
                if (res.ok) resolve({ code: codeText, redirectUri: redirectText, verifier })
                else reject(toError(res))
              }))
            })
          })
        })
      }),
      abortAuthorize: () => f.Client_AbortAuthorize(self),

      /** Exchanges the authorization code (public client). @param {string} code @param {string} verifier @param {string} redirectUri */
      getToken: (code, verifier, redirectUri) => tokenExchange(args => f.Client_GetToken(self, applicationId, str(code), str(verifier), str(redirectUri), ...args)),
      /** @param {string} refreshToken */
      refreshToken: refreshToken => tokenExchange(args => f.Client_RefreshToken(self, applicationId, str(refreshToken), ...args)),
      /** @param {string} accessToken */
      updateToken: accessToken => resultCall(args => f.Client_UpdateToken(self, TOKEN_TYPE_BEARER, str(accessToken), ...args)),
      /** Revokes every token of this application for the user. @param {string} token */
      revokeToken: token => resultCall(args => f.Client_RevokeToken(self, applicationId, str(token), ...args)),

      /** @returns {string | null} display name of the connected user */
      currentUserName: () => scoped(null, f.UserHandle_Drop, user => {
        if (!f.Client_GetCurrentUserV2(self, user)) return null
        return outString(out => f.UserHandle_DisplayName(user, out))
      }),

      /** @param {SdkActivity} activity @returns {Promise<void>} */
      updateRichPresence: activity => withActivity(activity, act => resultCall(args => f.Client_UpdateRichPresence(self, act, ...args))),
      clearRichPresence: () => f.Client_ClearRichPresence(self),

      drop () {
        if (dropped) return
        dropped = true
        f.Client_Drop(self)
        koffi.free(self)
      }
    }
  }

  return {
    version: `${f.Client_GetVersionMajor()}.${f.Client_GetVersionMinor()}.${f.Client_GetVersionPatch()}`,
    runCallbacks: () => f.RunCallbacks(),
    /** Scopes for account linking and rich presence ("openid sdk.social_layer_presence"). */
    defaultPresenceScopes: () => outString(out => f.Client_GetDefaultPresenceScopes(out)),
    /** @param {number} status */
    statusName: status => outString(out => f.Client_StatusToString(status, out)),
    /** @param {number} error */
    errorName: error => outString(out => f.Client_ErrorToString(error, out)),
    /** Number of callbacks the SDK still holds. */
    get pendingCallbacks () { return registered.size },
    withActivity,
    createClient
  }
}
