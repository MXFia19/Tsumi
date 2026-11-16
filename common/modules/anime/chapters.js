// AniSkip skip times -> player chapters. Pure module, tested by chapters.test.mjs.

/**
 * Player chapters ({ start, end, text } in milliseconds) covering the whole video from AniSkip results
 * (https://api.aniskip.com/v2/skip-times: { interval: { startTime, endTime }, skipType: 'op' | 'ed' | 'recap', episodeLength }).
 * Skip times are shifted by the length difference between the submitted episode and this video, sorted by start
 * (a recap before the opening comes first), and the gaps become "Episode" chapters. An "Intro" chapter covers the
 * start before the opening, a "Preview" one the end after the ending.
 * @param {any[]} results
 * @param {number} duration video length in seconds
 * @returns {{ start: number, end: number, text: string }[]}
 */
export function constructChapters (results, duration) {
  const total = Number(duration) * 1000
  if (!results?.length || !(total > 0)) return []
  const clamp = (value) => Math.max(0, Math.min(value, total))
  const chapters = results.map(result => {
    const diff = duration - (Number(result.episodeLength) || duration)
    return {
      start: clamp((result.interval.startTime + diff) * 1000),
      end: clamp((result.interval.endTime + diff) * 1000),
      text: String(result.skipType).toUpperCase()
    }
  }).filter(chapter => chapter.end > chapter.start)
  if (!chapters.length) return []
  const ed = chapters.find(({ text }) => text === 'ED')
  const recap = chapters.find(({ text }) => text === 'RECAP')
  if (recap) recap.text = 'Recap'

  chapters.sort((a, b) => a.start - b.start)
  if ((chapters[0].start | 0) !== 0) {
    chapters.unshift({ start: 0, end: chapters[0].start, text: chapters[0].text === 'OP' ? 'Intro' : 'Episode' })
  }
  const last = chapters[chapters.length - 1]
  if (ed) {
    if ((ed.end | 0) + 5000 - total < 0) chapters.push({ start: ed.end, end: total, text: 'Preview' })
  } else if ((last.end | 0) + 5000 - total < 0) {
    chapters.push({ start: last.end, end: total, text: 'Episode' })
  }

  // Gaps between two chapters (overlapping ones leave none).
  for (let i = 0, len = chapters.length - 2; i <= len; ++i) {
    const current = chapters[i]
    const next = chapters[i + 1]
    if ((next.start | 0) > (current.end | 0)) {
      chapters.push({ start: current.end, end: next.start, text: 'Episode' })
    }
  }

  chapters.sort((a, b) => a.start - b.start)
  return chapters
}
