// List changes sent to the other profiles ("Sync List Entries"), pure logic tested by listsync.test.mjs.
// Same rules as the iOS app (ios-native/Tsumi/Services/MediaListService.swift automaticSync).

/**
 * What an automatic progress update (the current profile now at `status`, episode `progress`) changes on another
 * profile's entry, null when nothing: that entry is already there or ahead (later episode, or completed while this
 * profile is still watching), so it is never lowered. A rewatch here is a first watch on a profile that never
 * finished the title, and completing it counts a rewatch only on a profile that was rewatching too. The score is
 * never part of it.
 * @param {{ status?: string, progress?: number, repeat?: number } | null | undefined} theirs entry of the other
 * profile, null / undefined when the title is not on its list
 * @param {string} status AniList status saved on the current profile (CURRENT, REPEATING, COMPLETED...)
 * @param {number} progress episode saved on the current profile
 * @returns {{ status: string, repeat?: number } | null} repeat: only when it changes
 */
export function automaticSync (theirs, status, progress) {
  if (!theirs) return { status: status === 'REPEATING' ? 'CURRENT' : status }
  const theirProgress = Number(theirs.progress) || 0
  if (theirProgress > progress) return null
  if (theirs.status === 'COMPLETED' && status !== 'COMPLETED') return null
  if (theirProgress === progress && (theirs.status === status || (theirs.status === 'REPEATING' && status === 'CURRENT'))) return null
  switch (status) {
    case 'COMPLETED':
      return theirs.status === 'REPEATING' && Number.isInteger(theirs.repeat) ? { status: 'COMPLETED', repeat: theirs.repeat + 1 } : { status: 'COMPLETED' }
    case 'CURRENT':
    case 'REPEATING':
      return { status: theirs.status === 'REPEATING' ? 'REPEATING' : 'CURRENT' }
    default:
      return { status }
  }
}
