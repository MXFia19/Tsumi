// Year in Review: shareable summary image (1080 x 1350 PNG) drawn on a canvas, then saved or copied
// through the Electron main process (electron/src/main/yearReview.js).
// iOS draws the same card with SwiftUI ImageRenderer (ios-native/Tsumi/UI/YearReview/YearReviewShareCard.swift).
import { IPC } from '@/modules/bridge.js'
import { hoursValue, formatNumber, formatShortDay } from './stats.js'

const WIDTH = 1080
const HEIGHT = 1350
const MARGIN = 64
const FONT = '"Inter", "Nunito Variable", system-ui, sans-serif'
const BACKGROUND = '#0e0f13'
const MUTED = 'rgba(255, 255, 255, 0.62)'

/** The --accent-color of the app (custom CSS variables), white by default. */
export function accentColor () {
  const value = getComputedStyle(document.documentElement).getPropertyValue('--accent-color').trim()
  return /^#[0-9a-f]{3,8}$/i.test(value) || /^(rgb|hsl)a?\(/i.test(value) ? value : '#FFFFFF'
}

async function loadImage (url, allowNetwork) {
  if (!url || !allowNetwork) return null
  try {
    const res = await fetch(url, { credentials: 'omit' })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    return await createImageBitmap(await res.blob())
  } catch {
    return new Promise(resolve => {
      const image = new Image()
      image.crossOrigin = 'anonymous'
      image.onload = () => resolve(image)
      image.onerror = () => resolve(null)
      image.src = url
    })
  }
}

function drawCover (ctx, image, x, y, width, height, radius, fallback) {
  ctx.save()
  ctx.beginPath()
  ctx.roundRect(x, y, width, height, radius)
  ctx.clip()
  if (image) {
    const scale = Math.max(width / image.width, height / image.height)
    const sourceWidth = width / scale
    const sourceHeight = height / scale
    ctx.drawImage(image, (image.width - sourceWidth) / 2, (image.height - sourceHeight) / 2, sourceWidth, sourceHeight, x, y, width, height)
  } else {
    ctx.fillStyle = fallback || '#22252d'
    ctx.fillRect(x, y, width, height)
  }
  ctx.restore()
}

function fitText (ctx, text, maxWidth) {
  if (ctx.measureText(text).width <= maxWidth) return text
  let value = text
  while (value.length > 1 && ctx.measureText(value + '…').width > maxWidth) value = value.slice(0, -1)
  return value.trimEnd() + '…'
}

function font (size, weight = 700) {
  return `${weight} ${size}px ${FONT}`
}

function statTile (ctx, x, y, width, value, label, accent) {
  ctx.fillStyle = 'rgba(255, 255, 255, 0.06)'
  ctx.beginPath()
  ctx.roundRect(x, y, width, 170, 28)
  ctx.fill()
  ctx.fillStyle = accent
  ctx.font = font(76, 800)
  ctx.fillText(fitText(ctx, value, width - 48), x + 28, y + 96)
  ctx.fillStyle = MUTED
  ctx.font = font(28, 600)
  ctx.fillText(fitText(ctx, label, width - 48), x + 28, y + 142)
}

function smallStat (ctx, x, y, width, value, label) {
  ctx.fillStyle = '#FFFFFF'
  ctx.font = font(44, 800)
  ctx.fillText(fitText(ctx, value, width), x, y)
  ctx.fillStyle = MUTED
  ctx.font = font(26, 600)
  ctx.fillText(fitText(ctx, label, width), x, y + 38)
}

async function draw ({ review, account, accent, allowNetwork }) {
  const { stats, media, year } = review
  const canvas = document.createElement('canvas')
  canvas.width = WIDTH
  canvas.height = HEIGHT
  const ctx = canvas.getContext('2d')
  try { await document.fonts?.ready } catch {}

  const top = stats.topAnime.map(item => ({ ...item, media: media[item.mediaId] || {} }))
  const hero = top[0]?.media
  const [heroImage, avatar, icon, ...covers] = await Promise.all([
    loadImage(hero?.banner || hero?.cover, allowNetwork),
    loadImage(account.avatar, allowNetwork),
    loadImage('./icon_filled.png', true),
    ...top.map(item => loadImage(item.media.cover, allowNetwork))
  ])

  // Background: hero banner fading into the page, accent glow
  ctx.fillStyle = BACKGROUND
  ctx.fillRect(0, 0, WIDTH, HEIGHT)
  if (heroImage) {
    ctx.globalAlpha = 0.42
    drawCover(ctx, heroImage, 0, 0, WIDTH, 600, 0)
    ctx.globalAlpha = 1
  }
  const fade = ctx.createLinearGradient(0, 120, 0, 600)
  fade.addColorStop(0, 'rgba(14, 15, 19, 0.3)')
  fade.addColorStop(1, BACKGROUND)
  ctx.fillStyle = fade
  ctx.fillRect(0, 0, WIDTH, 600)
  const glow = ctx.createRadialGradient(WIDTH, HEIGHT, 0, WIDTH, HEIGHT, 900)
  glow.addColorStop(0, hero?.color ? hero.color + '55' : 'rgba(255, 255, 255, 0.10)')
  glow.addColorStop(1, 'rgba(0, 0, 0, 0)')
  ctx.fillStyle = glow
  ctx.fillRect(0, 0, WIDTH, HEIGHT)

  // Header
  ctx.textBaseline = 'alphabetic'
  ctx.fillStyle = accent
  ctx.font = font(30, 800)
  ctx.letterSpacing = '6px'
  ctx.fillText('YEAR IN REVIEW', MARGIN, 120)
  ctx.letterSpacing = '0px'
  ctx.fillStyle = '#FFFFFF'
  ctx.font = font(84, 800)
  ctx.fillText(`My ${year} in anime`, MARGIN, 214)
  ctx.fillStyle = MUTED
  ctx.font = font(34, 600)
  ctx.fillText(fitText(ctx, account.name, WIDTH - MARGIN * 2 - 170), MARGIN, 268)
  if (avatar) {
    ctx.save()
    ctx.beginPath()
    ctx.arc(WIDTH - MARGIN - 64, 180, 64, 0, Math.PI * 2)
    ctx.clip()
    drawCover(ctx, avatar, WIDTH - MARGIN - 128, 116, 128, 128, 0)
    ctx.restore()
    ctx.strokeStyle = accent
    ctx.lineWidth = 5
    ctx.beginPath()
    ctx.arc(WIDTH - MARGIN - 64, 180, 66, 0, Math.PI * 2)
    ctx.stroke()
  }

  // Big numbers
  const tileWidth = (WIDTH - MARGIN * 2 - 2 * 24) / 3
  statTile(ctx, MARGIN, 320, tileWidth, formatNumber(stats.episodes), 'episodes', accent)
  statTile(ctx, MARGIN + tileWidth + 24, 320, tileWidth, formatNumber(hoursValue(stats.minutes)), 'hours', accent)
  statTile(ctx, MARGIN + (tileWidth + 24) * 2, 320, tileWidth, formatNumber(stats.titles), 'anime', accent)

  const smallWidth = (WIDTH - MARGIN * 2) / 4
  smallStat(ctx, MARGIN, 586, smallWidth - 20, formatNumber(stats.started), 'started')
  smallStat(ctx, MARGIN + smallWidth, 586, smallWidth - 20, formatNumber(stats.completed), 'completed')
  smallStat(ctx, MARGIN + smallWidth * 2, 586, smallWidth - 20, formatNumber(stats.dropped), 'dropped')
  smallStat(ctx, MARGIN + smallWidth * 3, 586, smallWidth - 20, stats.averageScore !== null ? `${stats.averageScore}` : '–', 'avg score')

  // Top anime covers
  ctx.fillStyle = '#FFFFFF'
  ctx.font = font(36, 800)
  ctx.fillText('Top anime', MARGIN, 712)
  const coverWidth = 176
  const coverHeight = 250
  const gap = 22
  const rowWidth = top.length * coverWidth + Math.max(0, top.length - 1) * gap
  const startX = top.length >= 5 ? (WIDTH - rowWidth) / 2 : MARGIN
  top.forEach((item, index) => {
    const x = startX + index * (coverWidth + gap)
    const y = 740
    drawCover(ctx, covers[index], x, y, coverWidth, coverHeight, 18, item.media.color)
    ctx.fillStyle = index === 0 ? accent : 'rgba(14, 15, 19, 0.85)'
    ctx.beginPath()
    ctx.arc(x + 30, y + 30, 22, 0, Math.PI * 2)
    ctx.fill()
    ctx.fillStyle = index === 0 ? BACKGROUND : '#FFFFFF'
    ctx.font = font(24, 800)
    ctx.textAlign = 'center'
    ctx.fillText(String(index + 1), x + 30, y + 39)
    ctx.textAlign = 'left'
    ctx.fillStyle = '#FFFFFF'
    ctx.font = font(23, 700)
    ctx.fillText(fitText(ctx, item.media.title || 'Unknown title', coverWidth), x, y + coverHeight + 36)
    ctx.fillStyle = MUTED
    ctx.font = font(21, 600)
    ctx.fillText(`${formatNumber(item.episodes)} ep${item.episodes === 1 ? '' : 's'}`, x, y + coverHeight + 66)
  })
  if (!top.length) {
    ctx.fillStyle = MUTED
    ctx.font = font(28, 600)
    ctx.fillText('No episodes tracked this year.', MARGIN, 780)
  }

  // Genres, studio, binge day
  const lines = []
  if (stats.genres.length) lines.push(['Top genres', stats.genres.slice(0, 3).map(genre => genre.name).join(' · ')])
  if (stats.studios.length) lines.push(['Top studio', stats.studios[0].name])
  if (stats.bingeDay) lines.push(['Biggest binge', `${formatShortDay(stats.bingeDay.date)} · ${stats.bingeDay.episodes} episode${stats.bingeDay.episodes === 1 ? '' : 's'}`])
  lines.slice(0, 3).forEach(([label, value], index) => {
    const y = 1132 + index * 50
    ctx.fillStyle = MUTED
    ctx.font = font(27, 600)
    ctx.fillText(label, MARGIN, y)
    ctx.fillStyle = '#FFFFFF'
    ctx.font = font(29, 700)
    ctx.fillText(fitText(ctx, value, WIDTH - MARGIN * 2 - 250), MARGIN + 250, y)
  })

  // Footer
  ctx.fillStyle = 'rgba(255, 255, 255, 0.08)'
  ctx.fillRect(MARGIN, HEIGHT - 96, WIDTH - MARGIN * 2, 2)
  if (icon) drawCover(ctx, icon, MARGIN, HEIGHT - 72, 44, 44, 10)
  ctx.fillStyle = MUTED
  ctx.font = font(26, 700)
  ctx.fillText('Tsumi · Year in Review', MARGIN + (icon ? 60 : 0), HEIGHT - 40)
  ctx.textAlign = 'right'
  ctx.fillText('Data from AniList', WIDTH - MARGIN, HEIGHT - 40)
  ctx.textAlign = 'left'

  return new Promise((resolve, reject) => {
    try {
      canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('Could not render the image')), 'image/png')
    } catch (error) {
      reject(error) // tainted canvas
    }
  })
}

/** Renders the summary PNG. Falls back to a card without remote images if they cannot be drawn. */
export async function renderShareImage ({ review, account }) {
  const accent = accentColor()
  try {
    return await draw({ review, account, accent, allowNetwork: true })
  } catch {
    return draw({ review, account, accent, allowNetwork: false })
  }
}

export function shareFileName (year) {
  return `tsumi-year-in-review-${year}.png`
}

/** Save dialog of the main process; browser download as a fallback. Returns { saved, path? }. */
export async function saveShareImage (blob, year) {
  const data = new Uint8Array(await blob.arrayBuffer())
  if (IPC?.invoke) {
    try {
      return await IPC.invoke('year-review:save-png', { name: shareFileName(year), data })
    } catch {}
  }
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = shareFileName(year)
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 10_000)
  return { saved: true }
}

/** Copies the PNG to the clipboard (main process, then the async clipboard API). */
export async function copyShareImage (blob) {
  const data = new Uint8Array(await blob.arrayBuffer())
  if (IPC?.invoke) {
    try {
      if (await IPC.invoke('year-review:copy-png', data)) return true
    } catch {}
  }
  try {
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
    return true
  } catch {
    return false
  }
}
