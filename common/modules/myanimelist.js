import { writable } from 'simple-store-svelte'
import Bottleneck from 'bottleneck'

import { malToken, refreshMalToken } from '@/modules/settings.js'
import { mediaCache, mapStatus, malListEntry } from '@/modules/cache.js'
import { sleep } from '@/modules/util.js'
import { printError } from '@/modules/networking.js'
import { retryDelay } from '@/modules/cachepolicy.js'
import { fuzzyDateString, localFuzzyDate, dateOnlyValue } from '@/modules/dates.js'
import { toMalScore } from '@/modules/scores.js'
import Debug from 'debug'
const debug = Debug('ui:myanimelist')

export const clientID = atob('ZDZjNTlhNjI4M2U1NWU3NGZlMDQyMDY4OTk0ZTRmYjY=') // app type MUST be set to other, do not generate a seed.

const queryFields = [
  'synopsis',
  'alternative_titles',
  'mean',
  'rank',
  'popularity',
  'num_list_users',
  'num_scoring_users',
  'related_anime',
  'media_type',
  'num_episodes',
  'status',
  'my_list_status',
  'start_date',
  'end_date',
  'start_season',
  'broadcast',
  'studios',
  'authors{first_name,last_name}',
  'source',
  'genres',
  'average_episode_duration',
  'rating'
]

/** True when `res` is a loaded list ({ data: { MediaList: [...] } }), false for a failed or unknown one. */
export function isMalList (res) {
  return Array.isArray(res?.data?.MediaList)
}

/** True when a my_list_status answer (PUT) is a list status, not an error ({}, { error }, null). */
function isListStatus (json) {
  return !!json && typeof json === 'object' && !Array.isArray(json) && !json.error && typeof json.status === 'string'
}

class MALClient {
  limiter = new Bottleneck({
    reservoir: 20,
    reservoirRefreshAmount: 20,
    reservoirRefreshInterval: 4 * 1000,
    maxConcurrent: 2,
    minTime: 1000
  })

  rateLimitPromise = null

  /** @type {import('simple-store-svelte').Writable<ReturnType<MALClient['getUserLists']>>} */
  userLists = writable()

  userID = malToken

  constructor () {
    debug('Initializing MyAnimeList Client for ID ' + this.userID?.viewer?.data?.Viewer?.id)
    this.limiter.on('failed', async (error, jobInfo) => {
      // A few retries with a growing delay, then the request fails: it was retried forever (500 every millisecond,
      // network errors every 5 s), and MyAnimeList being down kept every AniList section waiting for the lists.
      const networkError = !error?.status
      const time = retryDelay(error, jobInfo?.retryCount, { retries: 3, base: networkError ? 5 * 1000 : 2 * 1000, max: 60 * 1000 })
      if (time === null) {
        printError('Search Failed', 'Failed making request to MyAnimeList!\nTry again in a minute.\n', error)
        return
      }
      debug(`MyAnimeList request failed (${error?.status || error?.message}), retrying in ${time} ms`)
      if ((networkError || error.status === 429) && !this.rateLimitPromise) this.rateLimitPromise = sleep(time).then(() => { this.rateLimitPromise = null })
      return time
    })

    if (this.userID?.viewer?.data?.Viewer) {
      const lists = this.getUserLists({ sort: 'list_updated_at' })
      this.userLists.value = lists
      // A failed first load is tried again soon instead of at the next 15 minute refresh.
      lists.then(res => { if (!isMalList(res)) setTimeout(() => this.refreshUserLists(), 2 * 60 * 1000) })
      //  update userLists every 15 mins
      setInterval(() => this.refreshUserLists(), 1000 * 60 * 15)
    }
  }

  /**
   * Queries the lists again. A failed query keeps the previous lists: an empty or partial list made every entry
   * missing from it look like a new entry (score 0, start date today...) on the next progress update.
   */
  async refreshUserLists () {
    const updated = await this.getUserLists({ sort: 'list_updated_at' })
    const previous = await Promise.resolve(this.userLists.value).catch(() => null)
    if (isMalList(updated) || !isMalList(previous)) this.userLists.value = Promise.resolve(updated) // no need to have userLists await the entire query process while we already have previous values, (it's awful to wait 15+ seconds for the query to succeed with large lists)
    return updated
  }

  /**
   * @param {Record<string, any>} query
   * @param {Record<string, any>} body
   * @returns {Promise<{ ok: boolean, status: number, json: any }>} json: the answer (null when empty), {} when the request could not be sent
   */
  malSend (query, body = {}) {
    /** @type {RequestInit} */
    const options = {
      method: `${query.type}`,
      headers: {
        Authorization: `Bearer ${query.eToken ? query.eToken : query.token ? query.token : this.userID.token}`,
        'Content-Type': 'application/x-www-form-urlencoded'
      }
    }
    if (Object.keys(body).length > 0) {
      options.body = new URLSearchParams(body)
    }
    return this.handleRequest(query, options)
  }

  /**
   * JSON answer of a request, errors included ({ error }), {} when it could not be sent. Rejects when the request
   * still fails after the retries (network errors, 429, 5xx).
   * @param {Record<string, any>} query
   * @param {Record<string, any>} body
   * @returns {Promise<import('./mal').Query<any>>}
   */
  async malRequest (query, body = {}) {
    return (await this.malSend(query, body))?.json ?? null
  }

  failedRefresh = []

  /**
   * @param {Record<string, any>} query
   * @param {Record<string, any>} options
   * @returns {Promise<{ ok: boolean, status: number, json: any }>}
   */
  handleRequest = this.limiter.wrap(async (query, options) => {
    await this.rateLimitPromise
    const notSent = { ok: false, status: 0, json: {} }
    if (!query.eToken && (this.failedRefresh.includes(query.token ? query.token : this.userID.token) || (!query.token && this.userID.reauth))) return notSent
    if (!query.eToken && (Math.floor(Date.now() / 1000) >= ((query.token ? query.refresh_in : this.userID.refresh_in) || 0))) {
      const oauth = await this.refreshToken(query)
      if (!oauth) return notSent
      options.headers = {
        Authorization: `Bearer ${oauth.access_token}`,
        'Content-Type': 'application/x-www-form-urlencoded'
      }
    }
    const res = await fetch(`https://api.myanimelist.net/v2/${query.path}`, options) // network errors are retried by the limiter
    if (res.status === 429 || res.status >= 500) throw res
    let json = null
    const text = await res.text().catch(() => '')
    if (text) { // DELETE answers can have no body
      try {
        json = JSON.parse(text)
      } catch (error) {
        if (res.ok) printError('Search Failed', 'Failed making request to MyAnimeList!\nTry again in a minute.\n', error)
      }
    }
    if (!res.ok && res.status !== 404) {
      if (json) {
        for (const error of json?.errors || [json?.error]) {
          let code = error
          switch (error) {
            case 'forbidden':
              code = 403
              break
            case 'invalid_token':
              code = 401
              const oauth = await this.refreshToken(query)
              if (oauth) {
                options.headers = {
                  Authorization: `Bearer ${oauth.access_token}`,
                  'Content-Type': 'application/x-www-form-urlencoded'
                }
                return this.handleRequest(query, options)
              } else return notSent
            case 'invalid_content':
              code = 422
              break
            default:
              code = res?.status
          }
          printError('Search Failed', 'Failed making request to MyAnimeList!\nTry again in a minute.\n', code)
        }
      } else {
        printError('Search Failed', 'Failed making request to MyAnimeList!\nTry again in a minute.\n', res)
      }
    }
    return { ok: res.ok, status: res.status, json }
  })

  async refreshToken (query) {
    const oauth = await refreshMalToken(query.token ? query.token : this.userID.token) // refresh authorization token as it typically expires every 31 days. Refresh token also expires every 31 days, so we refresh every two weeks.
    if (oauth) {
      if (!query.token) {
        this.userID = malToken
      }
      return oauth
    }
    this.failedRefresh.push(query.token ? query.token : this.userID.token)
    return oauth
  }

  async malEntry (media, variables) {
    variables.idMal = media.idMal
    const res = await this.entry(variables)
    const entry = res?.data?.SaveMediaListEntry
    // Only a saved entry changes the cache, through update() so that it is saved and subscribers see it.
    if (!variables.token && entry && media?.id) {
      mediaCache.update(current => {
        if (current[media.id]) current[media.id] = { ...current[media.id], mediaListEntry: { ...(current[media.id].mediaListEntry || {}), ...entry } }
        return current
      })
    }
    return res
  }

  /** @returns {Promise<import('./mal').Query<{ MediaList: import('./mal').MediaList }>>} */
  async getUserLists (variables) {
    debug('Getting user lists')
    const limit = 1000 // max possible you can fetch
    let offset = 0
    let allMediaList = []
    let hasNextPage = true
    let failure = null

    // Check and replace specific sort values
    const customSorts = ['list_start_date_nan', 'list_finish_date_nan', 'list_progress_nan']
    if (customSorts.includes(variables.sort)) {
      variables.originalSort = variables.sort
      variables.sort = 'list_updated_at'
    }
    while (hasNextPage) {
      const query = {
        type: 'GET',
        path: `users/@me/animelist?fields=${queryFields}&nsfw=true&limit=${limit}&offset=${offset}&sort=${variables.sort}`
      }
      const res = await this.malRequest(query).catch(error => ({ error }))
      if (!Array.isArray(res?.data)) {
        failure = res?.error || res || 'No list in the answer'
        break
      }
      allMediaList = allMediaList.concat(res.data)
      if (res.data.length < limit) {
        hasNextPage = false
      } else {
        offset += limit
      }
    }
    if (failure) {
      // Never a partial or empty list: an entry missing from it would be sent as a new entry on the next update.
      debug('Failed to get the user lists', failure)
      return { data: null, errors: [{ message: 'Failed to load your MyAnimeList list.', status: failure?.status }] }
    }
    // Custom sorting based on original variables.sort value. Dates are calendar days, entries without one go last.
    if (variables.originalSort === 'list_start_date_nan') {
      allMediaList?.sort((a, b) => dateOnlyValue(b.node.my_list_status.start_date) - dateOnlyValue(a.node.my_list_status.start_date))
    } else if (variables.originalSort === 'list_finish_date_nan') {
      allMediaList?.sort((a, b) => dateOnlyValue(b.node.my_list_status.finish_date) - dateOnlyValue(a.node.my_list_status.finish_date))
    } else if (variables.originalSort === 'list_progress_nan') {
      allMediaList?.sort((a, b) => {
        const getSortValue = (item) => {
          const watched = item.node.my_list_status.num_episodes_watched ?? 0
          if (watched === 0) return Infinity
          if ((item.node.num_episodes ?? 0) === 0) return -watched
          const distance = (item.node.num_episodes ?? 0) - watched
          if (distance <= 0) return -Infinity - watched
          return distance + watched / 100000
        }
        return getSortValue(a) - getSortValue(b)
      })
    }

    return { data: { MediaList: allMediaList } }
  }

  /**
   * Applies a saved (listStatus) or deleted (null) entry to the lists, instead of querying the whole list again
   * (thousands of entries, several pages) after every episode. A new entry needs the media fields only the list query
   * returns: the lists are then queried again.
   * @param {number} idMal
   * @param {any} listStatus my_list_status answer, null when the entry was deleted
   */
  async patchUserList (idMal, listStatus) {
    const current = await Promise.resolve(this.userLists.value).catch(() => null)
    const list = current?.data?.MediaList
    const index = Array.isArray(list) ? list.findIndex(({ node }) => node?.id === idMal) : -1
    if (listStatus === null) {
      if (index >= 0) this.userLists.value = Promise.resolve({ ...current, data: { ...current.data, MediaList: list.filter((_, i) => i !== index) } })
      return
    }
    if (index < 0) {
      this.refreshUserLists().catch(error => debug('Failed to refresh the user lists', error))
      return
    }
    const item = list[index]
    const updated = { ...item, node: { ...item.node, my_list_status: { ...item.node.my_list_status, ...listStatus } } }
    // Most recently updated first, like the list_updated_at sort of the query.
    this.userLists.value = Promise.resolve({ ...current, data: { ...current.data, MediaList: [updated, ...list.filter((_, i) => i !== index)] } })
  }

  /**
   * List status of a title on an account, read fresh: null when it is not on the list. Rejects when it could not be
   * read. Synced profiles (Helper.updateEntry) read their own status so that it is never lowered.
   * @param {number} idMal
   * @param {{ token: string, refresh_in?: number }} profile
   */
  async listStatus (idMal, profile) {
    const res = await this.malSend({
      type: 'GET',
      path: `anime/${idMal}?fields=my_list_status{status,score,num_episodes_watched,is_rewatching,num_times_rewatched,start_date,finish_date}`,
      token: profile.token,
      refresh_in: profile.refresh_in
    })
    if (!res?.ok || !res.json?.id) throw new Error(res?.json?.message || res?.json?.error || 'Failed to read the MyAnimeList entry.')
    return res.json.my_list_status || null
  }

  /** @returns {Promise<import('./mal').Query<{ Viewer: import('./mal').Viewer }>>} */
  async viewer (token) {
    debug('Getting viewer')
    const query = {
      type: 'GET',
      path: 'users/@me',
      eToken: token
    }
    const res = await this.malRequest(query)
    const viewer = { data: { Viewer: res } }
    if (viewer?.data?.Viewer && !viewer?.data?.Viewer?.picture) {
      viewer.data.Viewer.picture = 'https://cdn.myanimelist.net/images/kaomoji_mal_white.png' // set default image if user doesn't have an image, viewer doesn't return the default image if none is set for whatever reason...
    }
    return viewer
  }

  /**
   * Saves an entry. Only the known fields are sent (MyAnimeList keeps the others): a progress update leaves the score
   * and the rewatch count alone. Answers `{ data: { SaveMediaListEntry } }` built from the saved status, or
   * `{ data: null, errors }` when it failed (an error answer counted as saved before).
   */
  async entry (variables) {
    debug(`Updating entry for ${variables.idMal}`)
    const query = {
      type: 'PUT',
      path: `anime/${variables.idMal}/my_list_status`,
      token: variables.token,
      refresh_in: variables.refresh_in
    }
    let start_date = fuzzyDateString(variables.startedAt)
    let finish_date = fuzzyDateString(variables.completedAt)
    if (start_date && finish_date && start_date > finish_date) {
      const today = new Date()
      const yesterday = new Date(today)
      yesterday.setDate(today.getDate() - 1)
      finish_date = fuzzyDateString(localFuzzyDate(today))
      start_date = fuzzyDateString(localFuzzyDate(yesterday))
    }
    const updateData = {
      status: mapStatus(variables.status),
      is_rewatching: !!variables.status?.includes('REPEATING'),
      num_watched_episodes: variables.episode || 0
    }
    if (Number.isInteger(variables.repeat)) updateData.num_times_rewatched = variables.repeat
    if (variables.score !== undefined && variables.score !== null) updateData.score = toMalScore(variables.score)
    if (start_date) updateData.start_date = start_date
    if (finish_date) updateData.finish_date = finish_date
    if (!updateData.status) delete updateData.status // never "status=undefined"
    const res = await this.malSend(query, updateData).catch(error => ({ ok: false, status: error?.status || 0, json: null }))
    if (!res?.ok || !isListStatus(res.json)) {
      debug(`Failed to update entry for ${variables.idMal}`, res?.status, res?.json?.error)
      return { data: null, errors: [{ message: res?.json?.message || res?.json?.error || 'Failed to update the MyAnimeList entry.', status: res?.status }] }
    }
    if (!variables.token) await this.patchUserList(variables.idMal, res.json)
    const saved = malListEntry(variables.id, res.json)
    return {
      data: {
        SaveMediaListEntry: {
          ...saved,
          // fields the answer leaves out
          status: saved.status ?? variables.status,
          progress: saved.progress ?? variables.episode,
          score: saved.score ?? variables.score,
          repeat: saved.repeat ?? variables.repeat,
          startedAt: saved.startedAt ?? variables.startedAt,
          completedAt: saved.completedAt ?? variables.completedAt
        }
      }
    }
  }

  /**
   * Deletes an entry: `{ data: { DeleteMediaListEntry: { deleted: true } } }`, or `{ data: null, errors }` when it
   * failed. 404: the entry was not on the list (any more).
   */
  async delete (variables) {
    debug(`Deleting entry for ${variables.idMal}`)
    const query = {
      type: 'DELETE',
      path: `anime/${variables.idMal}/my_list_status`,
      token: variables.token,
      refresh_in: variables.refresh_in
    }
    const res = await this.malSend(query).catch(error => ({ ok: false, status: error?.status || 0, json: null }))
    if (!res?.ok && res?.status !== 404) {
      debug(`Failed to delete entry for ${variables.idMal}`, res?.status)
      return { data: null, errors: [{ message: 'Failed to delete the MyAnimeList entry.', status: res?.status }] }
    }
    if (!variables.token) await this.patchUserList(variables.idMal, null)
    return { data: { DeleteMediaListEntry: { deleted: true } } }
  }
}

export const malClient = new MALClient()
