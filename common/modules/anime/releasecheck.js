// Release notifications of the schedule feeds (anime/animeschedule.js): the time a feed was checked up to.
// Pure module (no app imports), tested by releasecheck.test.mjs.

/**
 * Time a release feed was checked up to (`lastSub` / `lastDub` / `lastHentai`, Unix seconds), from the entries the
 * check processed: just after the newest airedAt / addedAt seen, never earlier than the stored time. It was the device
 * time: an episode the feed lists a little after its addedAt (scrape-to-publish delay, cached copy of the feed), or a
 * device clock ahead, was never announced (lastAni already uses AniList's times). An entry is new when one of its dates
 * is at or after the stored time, hence the second after the newest: that one is not announced twice.
 * @param {{ episode?: { airedAt?: string | number, addedAt?: string | number } }[]} entries entries of the check
 * @param {number} lastNotified stored time; 0 or 1 before the first check
 * @param {number} now device time (Unix seconds), used when no entry has a date
 * @returns {number}
 */
export function releaseCheckTime (entries, lastNotified, now) {
  const stored = lastNotified > 1 ? lastNotified : 0
  let newest = 0
  for (const entry of entries || []) {
    for (const date of [entry?.episode?.airedAt, entry?.episode?.addedAt]) {
      if (date == null || date === '') continue
      const time = Math.floor(new Date(date).getTime() / 1000)
      if (Number.isFinite(time) && time > newest) newest = time
    }
  }
  if (!newest) return stored || now
  return Math.max(newest + 1, stored)
}
