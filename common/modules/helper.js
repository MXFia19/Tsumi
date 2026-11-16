import { alToken, malToken, settings, sync, isAuthorized } from '@/modules/settings.js'
import { anilistClient } from '@/modules/anilist.js'
import { malClient, isMalList } from '@/modules/myanimelist.js'
import { malDubs } from '@/modules/anime/animedubs.js'
import { profiles } from '@/modules/settings.js'
import { cache, mediaCache, mapStatus, malListEntry } from '@/modules/cache.js'
import { getMediaMaxEp, hasZeroEpisode } from '@/modules/anime/anime.js'
import { codes, matchKeys, isValidNumber } from '@/modules/util.js'
import { fuzzyDateString, localFuzzyDate } from '@/modules/dates.js'
import { normalizeScore, fromAniListRawScore } from '@/modules/scores.js'
import { automaticSync } from '@/modules/sync/listsync.js'
import { toast } from 'svelte-sonner'
import Debug from 'debug'
const debug = Debug('ui:helper')

export default class Helper {
  static statusName = {
    CURRENT: 'Watching',
    PLANNING: 'Planning',
    COMPLETED: 'Completed',
    PAUSED: 'Paused',
    DROPPED: 'Dropped',
    REPEATING: 'Rewatching'
  }

  static sortMap (sort) {
    switch (sort) {
      case 'UPDATED_TIME_DESC':
        return 'list_updated_at'
      case 'STARTED_ON_DESC':
        return 'list_start_date_nan' // doesn't exist, therefore we use custom logic.
      case 'FINISHED_ON_DESC':
        return 'list_finish_date_nan' // doesn't exist, therefore we use custom logic.
      case 'PROGRESS_DESC':
        return 'list_progress_nan' // doesn't exist, therefore we use custom logic.
      case 'USER_SCORE_DESC':
        return 'list_score'
    }
  }

  static statusMap (status) {
    return mapStatus(status)
  }

  static airingMap (status) {
    switch (status) {
      case 'finished_airing':
        return 'FINISHED'
      case 'currently_airing':
        return 'RELEASING'
      case 'not_yet_aired':
        return 'NOT_YET_RELEASED'
    }
  }

  /**
   * Start and finish dates to save with a status: the known ones are kept (partial dates too), today is used for a
   * missing start date while watching and a missing finish date once completed.
   * @param {any} media
   * @param {string} status status saved (decides the finish date)
   * @param {string} [startStatus] status deciding the start date, `status` by default (an automatic update that
   * completes an entry still started it today when it had no start date)
   */
  static getFuzzyDate (media, status, startStatus = status) {
    const updatedDate = new Date()
    const fuzzyDate = localFuzzyDate(updatedDate)
    const hasDate = (date) => !!date?.year
    let startedAt = hasDate(media.mediaListEntry?.startedAt) ? media.mediaListEntry.startedAt : (['CURRENT', 'REPEATING'].includes(startStatus) ? fuzzyDate : undefined)
    let completedAt = hasDate(media.mediaListEntry?.completedAt) ? media.mediaListEntry.completedAt : (status === 'COMPLETED' ? fuzzyDate : undefined)
    const started = fuzzyDateString(startedAt)
    const completed = fuzzyDateString(completedAt)
    if (started && completed && started > completed) {
      const yesterday = new Date(updatedDate)
      yesterday.setDate(updatedDate.getDate() - 1)
      completedAt = fuzzyDate
      startedAt = localFuzzyDate(yesterday)
    }
    return { startedAt, completedAt }
  }

  static sanitiseObject (object = {}) {
    const safe = {}
    for (const [key, value] of Object.entries(object)) {
      if (value) safe[key] = value
    }
    return safe
  }

  static isAniAuth () {
    return alToken
  }

  static isMalAuth () {
    return malToken
  }

  static isAuthorized () {
    return isAuthorized()
  }

  static getClient () {
    return this.isAniAuth() ? anilistClient : malClient
  }

  static getUser () {
    return (alToken || malToken)?.viewer?.data?.Viewer
  }

  static getUserAvatar () {
    return this.getUser()?.avatar?.large || this.getUser()?.avatar?.medium || this.getUser()?.picture
  }

  static isUserSort (variables) {
    return ['UPDATED_TIME_DESC', 'STARTED_ON_DESC', 'FINISHED_ON_DESC', 'PROGRESS_DESC', 'USER_SCORE_DESC'].includes(variables?.sort)
  }

  static userLists (variables) {
    return (!this.isUserSort(variables) || variables.sort === 'UPDATED_TIME_DESC')
      ? this.getClient().userLists.value
      : this.getClient().getUserLists({ sort: (this.isAniAuth() ? variables.sort : this.sortMap(variables.sort)) })
  }

  /**
   * Saves a list entry (list editor, setStatus), or the entry of a synced profile when `variables.token` is set.
   * The editor shows the stored score rounded to 0-10 and sends it back with every save: an untouched score (85
   * would become 90, 7.5 would become 8) or rewatch count is not sent. That is marked on `variables` (scoreUnchanged,
   * repeatUnchanged), so the synced profiles saved next with `{ ...variables }` (Scoring.svelte) don't get them either.
   */
  static async entry (media, variables) {
    let res
    if (!variables.token) {
      const existing = (mediaCache.value?.[media.id] || media)?.mediaListEntry
      if (variables.score !== undefined && variables.score !== null) {
        const score = this.isAniAuth() ? fromAniListRawScore(variables.score) : normalizeScore(variables.score)
        if (Math.round(score) === Math.round(normalizeScore(existing?.score))) {
          delete variables.score
          variables.scoreUnchanged = true
        }
      }
      if (variables.repeat !== undefined && variables.repeat !== null && (Number(variables.repeat) || 0) === (existing?.repeat || 0)) {
        delete variables.repeat
        variables.repeatUnchanged = true
      }
      const { scoreUnchanged, repeatUnchanged, ...sent } = variables
      res = await this.getClient().entry(sent)
      if (res?.data?.SaveMediaListEntry) {
        // The answer has no notes or custom lists: merged into the cached entry.
        mediaCache.update((currentCache) => {
          const cached = currentCache[media.id] || media
          currentCache[media.id] = { ...cached, mediaListEntry: { ...(cached?.mediaListEntry || {}), ...res.data.SaveMediaListEntry } }
          return currentCache
        })
        window.dispatchEvent(new CustomEvent('notification-read', {
          detail: {
            id: media.id,
            episode: res?.data?.SaveMediaListEntry?.progress,
            episodes: media.episodes
          }
        }))
      }
    } else {
      // Synced profile: the score and rewatch count only when they were changed in the editor.
      const { scoreUnchanged, repeatUnchanged, ...sent } = variables
      if (scoreUnchanged) delete sent.score
      if (repeatUnchanged) delete sent.repeat
      if (variables.anilist) {
        res = await anilistClient.entry(sent)
      } else {
        res = await malClient.entry(sent)
      }
    }
    return res
  }

  /**
   * Deletes a list entry. Resolves to the answer when it was deleted, null when it failed (the local entry is kept).
   */
  static async delete (media, variables) {
    let res
    if (!variables.token) {
      res = await this.getClient().delete(variables)
      if (res?.data?.DeleteMediaListEntry?.deleted) {
        mediaCache.update((currentCache) => {
          if (currentCache[media.id]) currentCache[media.id] = { ...currentCache[media.id], mediaListEntry: undefined }
          return currentCache
        })
      }
    } else {
      if (variables.anilist) {
        res = await anilistClient.delete(variables)
      } else {
        res = await malClient.delete(variables)
      }
    }
    return res?.data?.DeleteMediaListEntry?.deleted ? res : null
  }

  /**
   * Updates the list entry after an episode was watched. Resolves to what happened, for the list update queue
   * (sync/listqueue.js): `updated`, `unchanged` or `skipped` (nothing to do, or it can never be done: TMDB title,
   * unidentified media...) are done; `failed` (not saved) and `deferred` (MyAnimeList list state unknown) can be tried
   * again later.
   * @param {{ media: any, episode?: any, failed?: boolean }} filemedia
   * @returns {Promise<{ status: 'updated' | 'unchanged' | 'skipped' | 'failed' | 'deferred', reason?: string }>}
   */
  static async updateEntry (filemedia) {
    // check if values exist
    if (!filemedia?.media || !this.isAuthorized()) return { status: 'skipped', reason: 'not signed in' }
    const { media, failed } = filemedia
    if (failed) {
      toast.error('Failed to Update Progress', {
        description: 'The currently playing media failed to be identified, episode progress will not be updated... You can fix this in the File Manager.',
        duration: 9000
      })
      return { status: 'skipped', reason: 'media not identified' }
    }
    // TMDB titles ("tmdb-<id>") are on no AniList or MyAnimeList list.
    if (!media.id || typeof media.id === 'string') return { status: 'skipped', reason: 'not an AniList media' }
    let cachedMedia = await cache.requestMedia(media.id).catch(() => null)
    if (!cachedMedia?.id) return { status: 'failed', reason: 'media unavailable' }
    debug(`Checking entry for ${cachedMedia?.title?.userPreferred}`)

    debug(`Media viability: ${cachedMedia?.status}, is from failed resolve: ${failed}`)
    if (cachedMedia.status === 'CANCELLED') return { status: 'skipped', reason: 'cancelled' } // allow for not yet released as sometimes anilist is slow at updating or a few episodes were potentially leaked.

    if (!this.isAniAuth()) {
      // MyAnimeList: the entry comes from the lists. With unknown lists (request failed) an existing entry would look
      // new and be overwritten (status, start date today, rewatch count...): the update waits for the lists.
      if (!cachedMedia.idMal) return { status: 'skipped', reason: 'not on MyAnimeList' }
      const userLists = await Promise.resolve(malClient.userLists.value).catch(() => null)
      if (!isMalList(userLists)) {
        debug(`MyAnimeList lists unknown, not updating ${cachedMedia.title?.userPreferred} for now`)
        return { status: 'deferred', reason: 'MyAnimeList list unavailable' }
      }
      const node = userLists.data.MediaList.find(({ node }) => node?.id === cachedMedia.idMal)?.node
      cachedMedia = { ...cachedMedia, mediaListEntry: malListEntry(cachedMedia.id, node?.my_list_status) }
    }

    // check if media can even be watched, ex: it was resolved incorrectly
    // some anime/OVA's can have a single episode, or some movies can have multiple episodes
    const zeroEpisode = await hasZeroEpisode(cachedMedia)
    const singleEpisode = ((!cachedMedia.episodes && (!isValidNumber(filemedia.episode) || Number(filemedia.episode) === 1)) | (cachedMedia.format === 'MOVIE' && cachedMedia.episodes === 1)) && 1 // movie check
    const videoEpisode = (Number(filemedia.episode) || singleEpisode) + (zeroEpisode ? 1 : 0)
    const mediaEpisode = getMediaMaxEp(cachedMedia) || singleEpisode

    debug(`Episode viability: ${videoEpisode}, ${mediaEpisode}, ${singleEpisode}`)
    if (!videoEpisode || !mediaEpisode) return { status: 'skipped', reason: 'no episode' }
    // check episode range, safety check if `failed` didn't catch this
    if (videoEpisode > mediaEpisode) return { status: 'skipped', reason: 'episode out of range' }

    const entry = cachedMedia.mediaListEntry
    const lists = entry?.customLists?.filter(list => list.enabled).map(list => list.name) || []
    const status = entry?.status === 'REPEATING' ? 'REPEATING' : 'CURRENT'
    const progress = entry?.progress

    debug(`User's progress: ${progress}, Media's progress: ${videoEpisode}`)
    // check user's own watch progress
    if (progress > videoEpisode) return { status: 'unchanged' }
    if (progress === videoEpisode && videoEpisode !== mediaEpisode && !singleEpisode) return { status: 'unchanged' }

    debug(`Updating entry for ${cachedMedia.title.userPreferred}`)
    // No score: a progress update leaves it alone (the cached score used to be sent back on the wrong scale).
    // An unknown MyAnimeList rewatch count is left out too (MyAnimeList keeps it).
    const variables = {
      repeat: entry?.repeat ?? (this.isAniAuth() ? 0 : undefined),
      id: cachedMedia.id,
      status,
      episode: videoEpisode,
      lists
    }
    if (videoEpisode === mediaEpisode && cachedMedia.status !== 'NOT_YET_RELEASED') { // no chance you can watch all episodes while it's not yet released, maybe a few but not a whole season...
      variables.status = 'COMPLETED'
      if (entry?.status === 'REPEATING' && Number.isInteger(entry.repeat)) variables.repeat = entry.repeat + 1
    }

    // Start date from the watching status, finish date (MyAnimeList finish_date) from the saved one: completing the
    // last episode sets it.
    Object.assign(variables, this.getFuzzyDate(cachedMedia, variables.status, status))
    if (entry?.status === variables.status && entry?.progress === variables.episode && (entry?.repeat || 0) === (variables.repeat || 0)) {
      debug(`No entry changes detected for ${cachedMedia.title.userPreferred}`)
      return { status: 'unchanged' }
    }

    const score = normalizeScore(entry?.score)
    const description = `Title: ${anilistClient.title(cachedMedia)}\nStatus: ${this.statusName[variables.status]}\nEpisode: ${videoEpisode} / ${getMediaMaxEp(cachedMedia) ? getMediaMaxEp(cachedMedia) : '?'}${score ? `\nYour Score: ${score}` : ''}`
    let res
    try {
      res = this.isAniAuth() ? await anilistClient.entry(variables) : await malClient.malEntry(cachedMedia, variables)
    } catch (error) {
      debug('Failed to update the list entry', error)
      res = null
    }
    const saved = !!res?.data?.SaveMediaListEntry
    if (saved) {
      window.dispatchEvent(new CustomEvent('notification-read', {
        detail: {
          id: media.id,
          episode: res.data.SaveMediaListEntry.progress,
          episodes: cachedMedia.episodes
        }
      }))
    }
    this.listToast(res, description, false)

    if (sync.value.length > 0) { // handle profile entry syncing
      for (const profile of profiles.value) {
        if (sync.value.includes(profile?.viewer?.data?.Viewer?.id) && !profile.reauth) { // expired sessions are skipped until logged in again
          let res
          try {
            res = await this.syncProgress(cachedMedia, profile, variables.status, videoEpisode)
          } catch (error) {
            debug('Failed to update the list entry of a synced account', error)
            res = null
          }
          if (res !== undefined) this.listToast(res, description, profile)
        }
      }
    }
    return saved ? { status: 'updated' } : { status: 'failed', reason: res?.errors?.[0]?.message || 'not saved' }
  }

  /**
   * Automatic progress update of a synced profile: its own entry is read first and never lowered (progress, status,
   * rewatch count, see sync/listsync.js), its own dates are kept, and no score is sent. Same rules as iOS.
   * @param {any} media AniList media
   * @param {any} profile synced profile
   * @param {string} status status saved on the current profile
   * @param {number} progress episode saved on the current profile
   * @returns {Promise<any>} the save answer, undefined when there is nothing to change; rejects when the entry of the
   * profile could not be read
   */
  static async syncProgress (media, profile, status, progress) {
    const aniList = !!profile.viewer?.data?.Viewer?.avatar
    if (!aniList && !media.idMal) return undefined
    const theirs = aniList ? await anilistClient.listEntry(media.id, profile.token) : malListEntry(media.id, await malClient.listStatus(media.idMal, profile))
    const plan = automaticSync(theirs, status, progress)
    if (!plan) return undefined
    const variables = {
      id: media.id,
      status: plan.status,
      episode: progress,
      ...this.getFuzzyDate({ mediaListEntry: theirs }, plan.status, plan.status === 'COMPLETED' ? 'CURRENT' : plan.status),
      ...(plan.repeat !== undefined ? { repeat: plan.repeat } : {})
    }
    if (aniList) return anilistClient.entry({ ...variables, token: profile.token })
    return malClient.malEntry(media, { ...variables, token: profile.token, refresh_in: profile.refresh_in })
  }

  static listToast (res, description, profile) {
    const who = (profile ? ' for ' + profile.viewer.data.Viewer.name + (profile.viewer?.data?.Viewer?.avatar ? ' (AniList)' : ' (MyAnimeList)') : '')
    if (res?.data?.mediaListEntry || res?.data?.SaveMediaListEntry) {
      debug(`List Updated ${who}: ${description.replace(/\n/g, ', ')}`)
      if (!profile && (settings.value.toasts.includes('All') || settings.value.toasts.includes('Successes'))) {
        toast.success('List Updated', {
          description,
          duration: 6000
        })
      }
    } else {
      const status = Number(res?.errors?.[0]?.status) || 429
      const error = `\n${status} - ${res?.errors?.[0]?.message || codes[status] || codes[429]}`
      debug(`Error: Failed to update user list${who} with: ${description.replace(/\n/g, ', ')} ${error}`)
      if (settings.value.toasts.includes('All') || settings.value.toasts.includes('Errors')) {
        toast.error('Failed to Update List' + who, {
          description: description + error,
          duration: 9000
        })
      }
    }
  }

  static getPaginatedMediaList (page, perPage, variables, mediaList) {
    debug('Getting custom paged media list')
    return (variables.hideSubs ? malDubs.dubLists.value : Promise.resolve()).then(dubLists => {
      const ids = this.isAniAuth() ? mediaList.filter(({ media }) => {
        if ((!variables.hideSubs || dubLists?.dubbed?.includes(media.idMal)) &&
            matchKeys(media, variables.search, ['title.userPreferred', 'title.english', 'title.romaji', 'title.native']) &&
            (!variables.genre || variables.genre.map(genre => genre.trim().toLowerCase()).every(genre => media.genres.map(genre => genre.trim().toLowerCase()).includes(genre))) &&
            (!variables.tag || variables.tag.map(tag => tag.trim().toLowerCase()).every(tag => media.tags.map(tag => tag.name.trim().toLowerCase()).includes(tag))) &&
            (!variables.season || variables.season === media.season) &&
            (!variables.year || variables.year === media.seasonYear) &&
            (!variables.format || (Array.isArray(variables.format) && variables.format.includes(media.format)) || variables.format === media.format) &&
            (!variables.format_not || (Array.isArray(variables.format_not) ? !variables.format_not.includes(media.format) : variables.format_not !== media.format)) &&
            (!variables.status || (typeof variables.status === 'string' && variables.status === media.status) || (Array.isArray(variables.status) && variables.status.includes(media.status))) &&
            (!variables.status_not || (typeof variables.status_not === 'string' && variables.status_not !== media.status) || (Array.isArray(variables.status_not) && !variables.status_not.includes(media.status))) &&
            (!variables.continueWatching || (media.status === 'FINISHED' || media.mediaListEntry?.progress < getMediaMaxEp(media, true)))) { // airing or on hiatus: an episode is out past the progress (nextAiringEpisode is missing on hiatus)
          return true
        }
      }).sort((a, b) => {
        if (this.isUserSort(variables)) {
          switch (variables.sort) {
            case 'STARTED_ON_DESC':
              return ((b.media?.mediaListEntry?.startedAt?.year || 0) * 10000 + (b.media?.mediaListEntry?.startedAt?.month || 0) * 100 + (b.media?.mediaListEntry?.startedAt?.day || 0)) -
                     ((a.media?.mediaListEntry?.startedAt?.year || 0) * 10000 + (a.media?.mediaListEntry?.startedAt?.month || 0) * 100 + (a.media?.mediaListEntry?.startedAt?.day || 0))
            case 'FINISHED_ON_DESC':
              return ((b.media?.mediaListEntry?.completedAt?.year || 0) * 10000 + (b.media?.mediaListEntry?.completedAt?.month || 0) * 100 + (b.media?.mediaListEntry?.completedAt?.day || 0)) -
                     ((a.media?.mediaListEntry?.completedAt?.year || 0) * 10000 + (a.media?.mediaListEntry?.completedAt?.month || 0) * 100 + (a.media?.mediaListEntry?.completedAt?.day || 0))
            case 'PROGRESS_DESC':
              const getSortValue = (media) => {
                const progress = media?.mediaListEntry?.progress ?? 0
                const totalEpisodes = media?.episodes ?? getMediaMaxEp(media) ?? 0
                if (progress === 0) return Infinity
                if (totalEpisodes === 0) return -progress
                const distance = totalEpisodes - progress
                return distance <= 0 ? -Infinity : distance
              }
              return getSortValue(a.media) - getSortValue(b.media)
            case 'USER_SCORE_DESC': // doesn't exist, AniList uses SCORE_DESC for both MediaSort and MediaListSort.
              return (b.media?.mediaListEntry?.score || 0) - (a.media?.mediaListEntry?.score || 0)
            case 'UPDATED_TIME_DESC':
              return (b.media?.mediaListEntry?.updatedAt || 0) - (a.media?.mediaListEntry?.updatedAt || 0)
          }
        }
        return 0
      }) // no need to handle sorting for this, we implemented sorting (above) for Anilist because Watching and Rewatching are separate lists. This is not the case for MyAnimeList, it uses "is_rewatching" boolean as an indicator instead.
        .map(({ media }) => (this.isUserSort(variables) ? media : media.id)) : mediaList.filter(({ node }) => {
        if ((!variables.hideSubs || dubLists?.dubbed?.includes(node.id)) &&
            matchKeys(node, variables.search, ['title', 'alternative_titles.en', 'alternative_titles.ja']) &&
            (!variables.season || variables.season.toLowerCase() === node.start_season?.season.toLowerCase()) &&
            (!variables.year || variables.year === node.start_season?.year) &&
            (!variables.format || (Array.isArray(variables.format) ? (variables.format.includes(node.media_type.toUpperCase()) || (variables.format.includes('TV_SHORT') && (node.media_type.toUpperCase() === 'TV') && (node.average_episode_duration < 1200))) && (!variables.format.includes('TV') || variables.format.includes('TV_SHORT') || (node.average_episode_duration >= 1200)) : ((variables.format === node.media_type.toUpperCase()) || ((variables.format === 'TV_SHORT') && (node.media_type.toUpperCase() === 'TV') && (node.average_episode_duration < 1200))) && ((variables.format !== 'TV') || (variables.format === 'TV_SHORT') || (node.average_episode_duration >= 1200)))) &&
            (!variables.format_not || (Array.isArray(variables.format_not) ? !((variables.format_not.includes(node.media_type.toUpperCase()) || (variables.format_not.includes('TV_SHORT') && (node.media_type.toUpperCase() === 'TV') && (node.average_episode_duration < 1200))) && (!variables.format_not.includes('TV') || variables.format_not.includes('TV_SHORT') || (node.average_episode_duration >= 1200))) : !(((variables.format_not === node.media_type.toUpperCase()) || ((variables.format_not === 'TV_SHORT') && (node.media_type.toUpperCase() === 'TV') && (node.average_episode_duration < 1200))) && ((variables.format_not !== 'TV') || (variables.format_not === 'TV_SHORT') || (node.average_episode_duration >= 1200))))) &&
            (!variables.status || (typeof variables.status === 'string' && variables.status === this.airingMap(node.status)) || (Array.isArray(variables.status) && variables.status.includes(this.airingMap(node.status)))) &&
            (!variables.status_not || (typeof variables.status_not === 'string' && variables.status_not !== this.airingMap(node.status)) || (Array.isArray(variables.status_not) && !variables.status_not.includes(this.airingMap(node.status))))) {
          // api does not provide airing episode or tags, additionally genres are inaccurate and tags do not exist.
          return true
        }
      }).map(({ node }) => node.id).filter(Boolean)
      if (!ids.length) return {}
      if (this.isUserSort(variables)) {
        debug(`Handling page media list with user specific sorting ${variables.sort}`)
        const updatedVariables = { ...variables }
        delete updatedVariables.sort // delete user sort as you can't sort by user specific sorting on AniList when logged into MyAnimeList.
        if (!this.isAniAuth()) { // MyAnimeList series format can be different from Anilist, we don't need to include this since we just filtered what is needed above.
          delete updatedVariables.format
          delete updatedVariables.format_not
        }
        const startIndex = (perPage * (page - 1))
        const endIndex = startIndex + perPage
        const paginatedIds = ids.slice(startIndex, endIndex)
        const hasNextPage = ids.length > endIndex
        const idIndexMap = paginatedIds.reduce((map, id, index) => { map[id] = index; return map }, {})
        return this.isAniAuth()
          ? {
              data: {
                Page: {
                  pageInfo: {
                    hasNextPage
                  },
                  media: paginatedIds
                }
              }
            }
          : anilistClient.searchIDS({ page: 1, perPage, idMal: paginatedIds, ...this.sanitiseObject(updatedVariables) }).then(res => {
            res.data.Page.pageInfo.hasNextPage = hasNextPage
            res.data.Page.media = res.data.Page.media.sort((a, b) => { return idIndexMap[a.idMal] - idIndexMap[b.idMal] })
            return res
          })
      } else {
        debug(`Handling page media list with non-specific sorting ${variables.sort}`)
        return anilistClient.searchIDS({ page, perPage, ...({ [this.isAniAuth() ? 'id' : 'idMal']: ids }), ...this.sanitiseObject(variables) }).then(res => {
          return res
        })
      }
    })
  }
}
