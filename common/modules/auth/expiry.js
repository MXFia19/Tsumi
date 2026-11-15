// AniList / MyAnimeList session expiry: a dead token (AniList 401 / "Invalid token", a passed JWT `exp`, or a
// failed MyAnimeList refresh) marks the profile `reauth`, stops being sent (public AniList queries keep
// working without it) and shows one persistent prompt per session: "Log in again" re-runs the login of that
// profile (swapProfiles keeps it and its settings), "Log out" removes it. A known AniList expiry also warns
// EXPIRY_WARNING_DAYS before. iOS: Services/SessionExpiry.swift + UI/Shell/ShellSessionExpiry.swift.
import { toast } from 'svelte-sonner'
import { alToken, malToken, profiles, sync, swapProfiles } from '@/modules/settings.js'
import { clientID } from '@/modules/myanimelist.js'
import { generateRandomString } from '@/modules/util.js'
import { SUPPORTS } from '@/modules/support.js'
import { IPC } from '@/modules/bridge.js'
import { sameToken, decodeTokenExpiry, tokenExpiryState, daysLeft, profileExpiry } from '@/modules/auth/token.js'
import Debug from 'debug'
const debug = Debug('ui:session')

/** Prompts shown this session (`${service}-${viewerId}-${kind}`). */
const prompted = new Set()

function isAniListProfile (profile) {
  return !!profile?.viewer?.data?.Viewer?.avatar
}

function serviceName (profile) {
  return isAniListProfile(profile) ? 'AniList' : 'MyAnimeList'
}

function profileKey (profile) {
  return `${isAniListProfile(profile) ? 'anilist' : 'mal'}-${profile?.viewer?.data?.Viewer?.id}`
}

/**
 * The stored profile (current or other) using this token.
 * @param {string} token
 * @returns {{ profile: object, current: boolean } | null}
 */
export function findProfile (token) {
  if (!token) return null
  if (alToken && sameToken(alToken.token, token)) return { profile: alToken, current: true }
  if (malToken && sameToken(malToken.token, token)) return { profile: malToken, current: true }
  const other = (profiles.value || []).find(profile => sameToken(profile?.token, token))
  return other ? { profile: other, current: false } : null
}

/**
 * Whether an AniList token can still be sent: not marked expired and its JWT `exp` not passed.
 * @param {string} token
 */
export function isAniListTokenUsable (token) {
  if (!token) return false
  if (findProfile(token)?.profile?.reauth) return false
  return tokenExpiryState(decodeTokenExpiry(token)) !== 'expired'
}

/** Opens the AniList login (implicit grant, the token comes back through 'altoken'). */
export function loginAniList () {
  IPC.emit(SUPPORTS.isAndroid ? 'open' : 'open-auth', `https://anilist.co/api/v2/oauth/authorize?client_id=${atob('MzU5NzE=')}&response_type=token`) // Change redirect_url to tsumi://alauth
}

/** Opens the MyAnimeList login (PKCE, the code comes back through 'maltoken'). */
export function loginMAL () {
  const state = generateRandomString(10)
  const challenge = generateRandomString(50)
  sessionStorage.setItem(state, challenge)
  IPC.emit(SUPPORTS.isAndroid ? 'open' : 'open-auth', `https://myanimelist.net/v1/oauth2/authorize?response_type=code&client_id=${clientID}&state=${state}&code_challenge=${challenge}&code_challenge_method=plain`) // Change redirect_url to tsumi://malauth
}

/** "Log in again": the login of the profile's service (the new token replaces the profile's). */
export function reauthenticate (profile) {
  if (!profile) return
  if (isAniListProfile(profile)) loginAniList()
  else loginMAL()
}

/** "Log out": signs the current profile out (the next one takes over) or removes another profile. */
export function logoutProfile (profile) {
  if (!profile) return
  const id = profile.viewer?.data?.Viewer?.id
  if ((alToken || malToken)?.viewer?.data?.Viewer?.id === id && sameToken((alToken || malToken)?.token, profile.token)) {
    swapProfiles(null)
    return
  }
  profiles.update(list => list.filter(other => other?.viewer?.data?.Viewer?.id !== id))
  if (sync.value.includes(id)) sync.value = sync.value.filter(syncId => syncId !== id)
}

/**
 * Persistent prompt for a profile, once per session and kind.
 * @param {object} profile
 * @param {'expired' | 'expiring'} [kind]
 */
export function promptSession (profile, kind = 'expired') {
  if (!profile?.viewer?.data?.Viewer) return
  const key = `${profileKey(profile)}-${kind}`
  if (prompted.has(key)) return
  prompted.add(key)
  const service = serviceName(profile)
  const name = profile.viewer.data.Viewer.name
  if (kind === 'expiring') {
    const days = daysLeft(profileExpiry(profile))
    toast.warning(`Your ${service} session expires soon`, {
      description: `The session of ${name} ends in ${days} day${days === 1 ? '' : 's'}. Log in again to keep your list in sync.`,
      duration: Infinity,
      action: { label: 'Log in again', onClick: () => reauthenticate(profile) }
    })
    return
  }
  toast.error(`Your ${service} session has expired`, {
    description: `${name} is signed out of ${service}: list updates are paused until you log in again.`,
    duration: Infinity,
    action: { label: 'Log in again', onClick: () => reauthenticate(profile) },
    cancel: { label: 'Log out', onClick: () => logoutProfile(profile) }
  })
}

/**
 * A token was refused (or its refresh failed): marks its profile `reauth` and prompts once.
 * @param {string} token
 */
export function markSessionExpired (token) {
  const found = findProfile(token)
  if (!found) return
  const { profile, current } = found
  if (!profile.reauth) {
    debug(`${serviceName(profile)} session of ${profile.viewer?.data?.Viewer?.name} expired`)
    if (current) {
      profile.reauth = true
      localStorage.setItem(isAniListProfile(profile) ? 'ALviewer' : 'MALviewer', JSON.stringify(profile))
      profiles.update(list => list) // refreshes the current profile shown by Profiles.svelte
    } else {
      profiles.update(list => list.map(other => sameToken(other?.token, token) ? { ...other, reauth: true } : other))
    }
  }
  promptSession({ ...profile, reauth: true }, 'expired')
}

/**
 * Startup check: the current profile, and the other profiles kept in sync. Expired AniList tokens (JWT `exp`)
 * are marked; profiles already marked are prompted again (once per session); AniList tokens ending within
 * EXPIRY_WARNING_DAYS get a warning.
 */
export function checkStoredSessions () {
  const current = alToken || malToken
  const others = (profiles.value || []).filter(profile => sync.value.includes(profile?.viewer?.data?.Viewer?.id))
  for (const profile of [current, ...others]) {
    if (!profile?.viewer?.data?.Viewer) continue
    if (profile.reauth) {
      promptSession(profile, 'expired')
      continue
    }
    if (!isAniListProfile(profile)) continue // MyAnimeList refreshes its tokens: prompted when a refresh fails
    const state = tokenExpiryState(profileExpiry(profile))
    if (state === 'expired') markSessionExpired(profile.token)
    else if (state === 'expiring') promptSession(profile, 'expiring')
  }
}
