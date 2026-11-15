// Hold to speed up (Shiru 6.9.0, #180): holding the Play/Pause key or the mouse button on the video plays faster
// while it is held, a short tap / click keeps its usual action. Pure logic (no imports, see holdspeed.test.mjs):
// PlayerPage.svelte wires its video through the callbacks. iOS port: ios-native/Tsumi/Player/PlayerHoldSpeed.swift.

/** A press longer than this (ms) is a hold. Longer than the double-click time, so a hold never ends in a dblclick. */
export const HOLD_DELAY = 500

/** Speeds offered by the `playerHoldSpeed` setting. */
export const HOLD_SPEEDS = [1.5, 2, 3]
export const DEFAULT_HOLD_SPEED = 2

/**
 * The `playerHoldSpeed` setting as one of HOLD_SPEEDS (the default when unknown).
 * @param {unknown} value
 */
export function holdSpeedOf (value) {
  const speed = Number(value)
  return HOLD_SPEEDS.includes(speed) ? speed : DEFAULT_HOLD_SPEED
}

/**
 * "2×", "1.5×"
 * @param {number} speed
 */
export function holdSpeedLabel (speed) {
  return `${Number(Number(speed).toFixed(2))}×`
}

/**
 * @typedef {Object} HoldSpeedPlayer
 * @property {() => boolean} canHold the setting is on and a video plays in this window (not external, not cast)
 * @property {() => boolean} blocked in sync with a Watch Together lobby: the hold is refused
 * @property {() => number} speed playback rate while held
 * @property {() => number} getRate
 * @property {(rate: number) => void} setRate
 * @property {() => boolean} isPaused
 * @property {(paused: boolean) => void} setPaused
 * @property {(speed: number | null) => void} onChange indicator: the speed while held, null when it ends
 * @property {() => void} onBlocked tells why the hold did nothing
 */

export class HoldSpeed {
  /** @type {HoldSpeedPlayer} */
  #player
  /** @type {ReturnType<typeof setTimeout> | null} */
  #timer = null
  /** rate before the hold, restored on release */
  #rate = 1
  /** rate set by the hold */
  #speed = 1
  #startedPaused = false
  /** @type {string | null} what is pressed ('key:Space', 'pointer'), null when nothing */
  source = null
  /** the faster speed is playing */
  active = false

  /** @param {HoldSpeedPlayer} player */
  constructor (player) {
    this.#player = player
  }

  /**
   * Key down (not a repeat) or button down.
   * @param {string} source
   * @param {number} [delay]
   * @returns {boolean} true: the release decides (`release`); false: not handled, do the usual action now
   */
  press (source, delay = HOLD_DELAY) {
    if (this.source || !this.#player.canHold()) return false
    this.source = source
    this.#timer = setTimeout(() => this.#activate(), delay)
    this.#timer.unref?.()
    return true
  }

  /**
   * Key up or button up.
   * @param {string} source
   * @returns {'tap' | 'hold' | null} 'tap': a short press, do the usual action; 'hold': it was held (nothing more to
   * do, a click that follows should be ignored); null: this source was not pressed
   */
  release (source) {
    if (!this.source || source !== this.source) return null
    this.source = null
    if (this.#timer) {
      clearTimeout(this.#timer)
      this.#timer = null
      return 'tap'
    }
    this.#stop(true)
    return 'hold'
  }

  /** Window blur, other file, player hidden or closed: ends the press and the hold, without the tap action. */
  cancel () {
    if (this.#timer) clearTimeout(this.#timer)
    this.#timer = null
    this.source = null
    this.#stop(true)
  }

  /** The video paused or ended while held: back to the normal rate now (the release then does nothing more). */
  interrupt () {
    this.#stop(false)
  }

  #activate () {
    this.#timer = null
    if (!this.source) return
    const player = this.#player
    if (player.blocked()) {
      player.onBlocked()
      return
    }
    if (!player.canHold()) return
    this.#rate = player.getRate()
    this.#speed = player.speed()
    this.#startedPaused = player.isPaused()
    this.active = true
    player.setRate(this.#speed)
    if (this.#startedPaused) player.setPaused(false)
    player.onChange(this.#speed)
  }

  /** @param {boolean} restorePause pause again when the hold started paused */
  #stop (restorePause) {
    if (!this.active) return
    this.active = false
    const player = this.#player
    // A rate chosen while held (the [ / ] keys) is kept.
    if (Math.abs(player.getRate() - this.#speed) < 0.01) player.setRate(this.#rate)
    if (restorePause && this.#startedPaused && !player.isPaused()) player.setPaused(true)
    player.onChange(null)
  }
}
