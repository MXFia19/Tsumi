import JASSUB from 'jassub'
import { hex2arr, bin2hex } from 'uint8-util'
import { subRx, videoRx } from '@/modules/util.js'
import { convertSubText } from '@/modules/subconvert.js'
import { settings } from '@/modules/settings.js'
import clipboard from '@/modules/clipboard.js'
import { SUPPORTS } from '@/modules/support.js'

const defaultHeader = `[Script Info]
Title: English (US)
ScriptType: v4.00+
WrapStyle: 0
PlayResX: 1280
PlayResY: 720
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default, ${settings.value.font?.name.toLowerCase() || 'Roboto Medium'},52,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2.6,0,2,20,20,46,1
[Events]

`
const stylesRx = /^Style:[^,]*/gm
export default class Subtitles {
  constructor (video, files, selected, onHeader) {
    this.video = video
    this.selected = selected || null
    this.files = files || []
    this.headers = []
    this.tracks = []
    this._tracksString = []
    this._stylesMap = []
    this.fonts = ['/Roboto.ttf', './NotoSansCJK.otf']
    this.renderer = null
    this.parsed = false
    this.stream = null
    this.parser = null
    this.current = 0
    this.onHeader = onHeader
    this.videoFiles = files.filter(file => videoRx.test(file.name))
    this.subtitleFiles = []
    this.timeout = null
    /** subtitle offset in seconds (positive shows them earlier), also given to renderers created later */
    this.timeOffset = 0
    this.handleFile = ({ detail }) => {
      if (this.selected) {
        const uint8 = hex2arr(bin2hex(detail))
        this.fonts.push(uint8)
        this.renderer?.addFont(uint8)
      }
    }
    this.handleSubtitle = ({ detail }) => {
      const { subtitle, trackNumber } = detail
      if (this.selected) {
        const string = JSON.stringify(subtitle)
        if (this._tracksString[trackNumber] && !this._tracksString[trackNumber].has(string)) {
          this._tracksString[trackNumber].add(string)
          const assSub = this.constructSub(subtitle, this.headers[trackNumber].type !== 'ass', this.tracks[trackNumber].length, trackNumber)
          this.tracks[trackNumber].push(assSub)
          if (this.current === trackNumber) this.renderer?.createEvent(assSub)
        }
      }
    }

    this.handleTracks = ({ detail }) => {
      if (this.selected) {
        for (const track of detail) {
          if (!this.tracks[track.number]) {
            // overwrite webvtt or other header with custom one
            if (track.type !== 'ass') track.header = defaultHeader
            this.tracks[track.number] = []
            this._tracksString[track.number] = new Set()
            this.headers[track.number] = track
            this._stylesMap[track.number] = {
              Default: 0
            }
            const styleMatches = track.header.match(stylesRx) ?? []
            for (let i = 0; i < styleMatches.length; ++i) {
              const style = styleMatches[i].replace('Style:', '').trim()
              this._stylesMap[track.number][style] = i + 1
            }

            this.onHeader()
          }
        }
        this.initSubtitleRenderer()
        const tracks = this.headers?.filter(t => t)
        if (tracks?.length && settings.value.subtitleLanguage) {
          if (tracks.length === 1) {
            this.selectCaptions(tracks[0].number)
          } else {
            let wantedTrack = tracks.find(({ language }) => {
              if (language == null) language = 'eng'
              return language === settings.value.subtitleLanguage
            })
            if (!wantedTrack) wantedTrack = tracks.find(track => (track.name?.toLowerCase() ?? '').includes(settings.value.subtitleLanguage.toLowerCase()))
            if (wantedTrack) return this.selectCaptions(wantedTrack.number)

            const englishTrack = tracks.find(({ language }) => language == null || language === 'eng')
            if (englishTrack) return this.selectCaptions(englishTrack.number)

            this.selectCaptions(tracks[0].number)
          }
        }
      }
    }
    this.handleClipboardText = ({ detail }) => {
      for (const { text, type } of detail) {
        if (text.startsWith('[Script Info]')) this.addSingleSubtitleFile(new File([text], 'Subtitle', { type }))
      }
    }
    this.handleClipboardFiles = ({ detail }) => {
      for (const file of detail) {
        if (subRx.test(file.name)) this.addSingleSubtitleFile(file)
      }
    }
    this.handleSubtitleFile = ({ detail }) => {
      this.addSingleSubtitleFile(new File([detail.data], detail.name))
    }

    // Subtitles come from the stream sources, or are pasted/dropped by the user
    clipboard.on('text', this.handleClipboardText)
    clipboard.on('files', this.handleClipboardFiles)
  }

  // Default no-op handlers, shadowed by the instance handlers assigned in the constructor
  handleTracks () { }
  handleSubtitle () { }
  handleFile () { }
  handleSubtitleFile () { }

  async addSingleSubtitleFile (file) {
    // lets hope there's no more than 100 subtitle tracks in a file
    const index = 100 + this.headers.length
    this.subtitleFiles[index] = file
    const dot = file.name.lastIndexOf('.')
    const type = dot === -1 ? '' : file.name.substring(dot + 1).toLowerCase()
    const subname = dot === -1 ? file.name : file.name.slice(0, dot)
    // sub name could contain video name with or without extension, possibly followed by lang, or not.
    const videoName = this.selected?.name || ''
    const name = !videoName
      ? subname
      : subname.includes(videoName)
        ? subname.replace(videoName, '')
        : subname.replace(videoName.slice(0, videoName.lastIndexOf('.')), '')
    this.headers[index] = {
      header: defaultHeader,
      language: name.replace(/[,._-]/g, ' ').trim() || 'Track ' + index,
      number: index,
      type
    }
    this.onHeader()
    this.tracks[index] = []
    const subtitles = convertSubText(await file.text(), type)
    // Destroyed while the file was read (episode changed, player closed): the caller sees the missing header.
    if (!this.headers?.[index]) return index
    if (subtitles) {
      if (typeof subtitles === 'string') this.headers[index].header = subtitles
      else this.headers[index].header += subtitles.join('\n')
      // Nothing selected yet, or this track was selected while its file was still loading: (re)render it now.
      if (!this.current || this.current === index) {
        this.current = index
        this.initSubtitleRenderer()
        this.selectCaptions(this.current)
        this.onHeader()
      }
    } else console.error(`Failed to load the file ${file.name} as it is not a subtitle file.`)
    return index
  }

  /** @param {number} offset seconds, positive shows the subtitles earlier */
  setTimeOffset (offset) {
    this.timeOffset = Number.isFinite(Number(offset)) ? Number(offset) : 0
    if (this.renderer) this.renderer.timeOffset = this.timeOffset
  }

  initSubtitleRenderer () {
    if (!this.renderer) {
      const options = {
        video: this.video,
        subContent: defaultHeader,
        fonts: this.fonts,
        offscreenRender: SUPPORTS.offscreenRender,
        libassMemoryLimit: 1024,
        libassGlyphLimit: 80000,
        maxRenderHeight: parseInt(settings.value.subtitleRenderHeight) || 0,
        fallbackFont: settings.value.font?.name || 'roboto medium',
        availableFonts: {
          'roboto medium': './Roboto.ttf',
          'noto sans cjk regular': './NotoSansCJK.otf'
        },
        workerUrl: new URL('jassub/dist/jassub-worker.js', import.meta.url).toString(),
        wasmUrl: new URL('jassub/dist/jassub-worker.wasm', import.meta.url).toString(),
        legacyWasmUrl: new URL('jassub/dist/jassub-worker.wasm.js', import.meta.url).toString(),
        modernWasmUrl: new URL('jassub/dist/jassub-worker-modern.wasm', import.meta.url).toString(),
        useLocalFonts: settings.value.missingFont,
        dropAllBlur: settings.value.disableSubtitleBlur,
        timeOffset: this.timeOffset
      }
      if (SUPPORTS.isAndroid) JASSUB._hasBitmapBug = true
      this.renderer = new JASSUB(options)
      this.renderer?.setDefaultFont('noto sans cjk regular')
    }
  }

  /** Kept for callers of the class API: see modules/subconvert.js. */
  static convertSubText (text, type) {
    return convertSubText(text, type)
  }

  constructSub (subtitle, isNotAss, subtitleIndex, trackNumber) {
    if (isNotAss === true) { // converts VTT or other to SSA
      const matches = subtitle.text.match(/<[^>]+>/g) // create array of all tags
      if (matches) {
        matches.forEach(match => {
          if (/<\//.test(match)) { // check if its a closing tag
            subtitle.text = subtitle.text.replace(match, match.replace('</', '{\\').replace('>', '0}'))
          } else {
            subtitle.text = subtitle.text.replace(match, match.replace('<', '{\\').replace('>', '1}'))
          }
        })
      }
      // replace all html special tags with normal ones
      subtitle.text = subtitle.text.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, '\\h').replace(/\r?\n/g, '\\N')
    }
    return {
      Start: subtitle.time,
      Duration: subtitle.duration,
      Style: this._stylesMap[trackNumber][subtitle.style || 'Default'] || 0,
      Name: subtitle.name || '',
      MarginL: Number(subtitle.marginL) || 0,
      MarginR: Number(subtitle.marginR) || 0,
      MarginV: Number(subtitle.marginV) || 0,
      Effect: subtitle.effect || '',
      Text: subtitle.text || '',
      ReadOrder: 1,
      Layer: Number(subtitle.layer) || 0,
      _index: subtitleIndex
    }
  }

  selectCaptions (trackNumber) {
    if (trackNumber != null) {
      this.current = Number(trackNumber)
      // A track picked while there is no renderer yet: OFF (the show's remembered choice) was applied before any file
      // loaded, so addSingleSubtitleFile never created it, and nothing would ever show in this episode.
      if (this.current !== -1 && this.headers?.[this.current]) this.initSubtitleRenderer()
      this.onHeader()
      if (this.headers) {
        this.renderer?.setTrack(this.current !== -1 ? this.headers[this.current].header.slice(0, -1) : defaultHeader)
        if (this.tracks[this.current]) {
          if (this.renderer) for (const subtitle of this.tracks[this.current]) this.renderer.createEvent(subtitle)
        }
      }
    }
  }

  destroy () {
    clipboard.off('text', this.handleClipboardText)
    clipboard.off('files', this.handleClipboardFiles)
    this.stream?.destroy()
    this.parser?.destroy()
    this.renderer?.destroy()
    this.files = null
    this.video = null
    this.selected = null
    this.tracks = null
    this.headers = null
    this.onHeader()
  }
}
