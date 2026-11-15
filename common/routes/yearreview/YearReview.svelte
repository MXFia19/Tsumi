<script>
  import { onDestroy } from 'svelte'
  import { fade } from 'svelte/transition'
  import { yearReviewView, closeYearReview, reviewAccount, loadYearReview, loadYears } from '@/modules/yearreview/yearreview.js'
  import { renderShareImage, saveShareImage, copyShareImage } from '@/modules/yearreview/shareImage.js'
  import { modal } from '@/modules/navigation.js'
  import { click } from '@/modules/click.js'
  import ReviewContent from '@/routes/yearreview/components/ReviewContent.svelte'
  import { X, RefreshCw, Download, Copy, LogIn } from 'lucide-svelte'

  let open = false
  let account = reviewAccount()
  let years = []
  let year = new Date().getFullYear()
  let review = null
  let error = null
  let loading = false
  let progress = { message: '', fraction: 0, wait: 0 }
  let controller = null
  let feedback = ''
  let feedbackTimer = null
  let sharing = false
  let scroller

  const unsubscribe = yearReviewView.subscribe(value => {
    if (value.open && !open) start(value.year)
    else if (!value.open && open) stop()
    open = value.open
  })

  async function start (requestedYear) {
    modal.close(modal.PROFILE)
    account = reviewAccount()
    review = null
    error = null
    feedback = ''
    year = requestedYear || new Date().getFullYear()
    years = [year]
    if (account.kind !== 'anilist') return
    load(year)
    const offered = await loadYears().catch(() => [])
    if (!open) return
    years = [...new Set([...offered, year])].sort((a, b) => b - a)
  }

  function stop () {
    controller?.abort()
    controller = null
    loading = false
    clearTimeout(feedbackTimer)
  }

  async function load (target, force = false) {
    controller?.abort()
    const current = new AbortController()
    controller = current
    year = target
    review = null
    error = null
    loading = true
    progress = { message: 'Loading…', fraction: 0, wait: 0 }
    scroller?.scrollTo?.({ top: 0 })
    try {
      const result = await loadYearReview({
        year: target,
        force,
        signal: current.signal,
        onProgress: value => { if (controller === current) progress = { wait: 0, ...value } }
      })
      if (controller === current) review = result
    } catch (e) {
      if (controller === current && e?.name !== 'AbortError') error = e?.message || String(e)
    } finally {
      if (controller === current) {
        loading = false
        controller = null
      }
    }
  }

  function showFeedback (text) {
    feedback = text
    clearTimeout(feedbackTimer)
    feedbackTimer = setTimeout(() => (feedback = ''), 4_000)
  }

  async function share (copy) {
    if (!review || sharing) return
    sharing = true
    try {
      const blob = await renderShareImage({ review, account })
      if (copy) {
        showFeedback((await copyShareImage(blob)) ? 'Image copied to the clipboard' : 'Could not copy the image')
      } else {
        const result = await saveShareImage(blob, review.year)
        if (result?.saved) showFeedback(result.path ? `Saved to ${result.path}` : 'Image saved')
        else if (result?.error) showFeedback(`Could not save the image: ${result.error}`)
      }
    } catch (e) {
      showFeedback(`Could not create the image: ${e?.message || e}`)
    } finally {
      sharing = false
    }
  }

  function login () {
    closeYearReview()
    modal.open(modal.PROFILE, true)
  }

  function keydown (event) {
    if (open && event.key === 'Escape') {
      event.stopPropagation()
      closeYearReview()
    }
  }

  // Mouse "back" closes the review instead of navigating the page underneath.
  function mouseup (event) {
    if (open && event.button === 3) {
      event.preventDefault()
      event.stopPropagation()
      closeYearReview()
    }
  }
  window.addEventListener('mouseup', mouseup, true)

  onDestroy(() => {
    unsubscribe()
    stop()
    window.removeEventListener('mouseup', mouseup, true)
  })
</script>

<svelte:window on:keydown={keydown} />

{#if open}
  <div class='year-review position-fixed d-flex flex-column' transition:fade={{ duration: 150 }} role='dialog' aria-modal='true' aria-label='Year in Review'>
    <div class='toolbar d-flex align-items-center flex-wrap'>
      <div class='toolbar-title font-weight-very-bold mr-auto'>Year in Review</div>
      {#if account.kind === 'anilist'}
        <select class='form-control year-select bg-dark' value={year} on:change={event => load(Number(event.currentTarget.value))} aria-label='Year'>
          {#each years as option (option)}
            <option value={option}>{option}</option>
          {/each}
        </select>
        <button type='button' class='btn tool-btn d-flex align-items-center' title='Refresh from AniList' disabled={loading} use:click={() => load(year, true)}>
          <RefreshCw size='1.8rem' />
        </button>
        <button type='button' class='btn tool-btn d-flex align-items-center' title='Save the summary image' disabled={!review?.stats?.hasData || sharing} use:click={() => share(false)}>
          <Download size='1.8rem' /><span class='d-none d-md-inline ml-5'>Save image</span>
        </button>
        <button type='button' class='btn tool-btn d-flex align-items-center' title='Copy the summary image' disabled={!review?.stats?.hasData || sharing} use:click={() => share(true)}>
          <Copy size='1.8rem' /><span class='d-none d-md-inline ml-5'>Copy</span>
        </button>
      {/if}
      <button type='button' class='btn btn-square tool-btn d-flex align-items-center justify-content-center' title='Close' use:click={closeYearReview}>
        <X size='2rem' strokeWidth='3' />
      </button>
    </div>
    {#if feedback}
      <div class='feedback font-size-14' transition:fade={{ duration: 120 }}>{feedback}</div>
    {/if}

    <div class='scroller flex-grow-1' bind:this={scroller}>
      <div class='content'>
        {#if account.kind !== 'anilist'}
          <div class='notice text-center'>
            <h2 class='font-weight-very-bold'>Year in Review needs AniList</h2>
            {#if account.kind === 'mal'}
              <p class='text-muted'>Year in Review isn't supported for MyAnimeList accounts yet: it is built from your AniList list activity (episodes watched, completions, scores), which MyAnimeList doesn't provide.</p>
              <p class='text-muted'>Add an AniList profile to see your year.</p>
            {:else}
              <p class='text-muted'>It is built from your AniList list activity: episodes watched, completions, scores. Log in with AniList to see your year.</p>
            {/if}
            <button type='button' class='btn btn-lg d-inline-flex align-items-center mt-10' use:click={login}>
              <LogIn size='1.8rem' class='mr-10' /> Log in with AniList
            </button>
          </div>
        {:else if loading}
          <div class='notice text-center'>
            <h2 class='font-weight-very-bold'>Building your {year}…</h2>
            <div class='progress-track mx-auto mt-20'><div class='progress-fill' style='width: {Math.round((progress.fraction || 0) * 100)}%'></div></div>
            <p class='text-muted mt-15'>{progress.message}</p>
            {#if progress.wait}
              <p class='wait font-size-14'>AniList is limiting requests right now, resuming in {progress.wait}s…</p>
            {/if}
            <p class='text-muted font-size-12'>The first load of a year can take a minute. It is cached afterwards.</p>
          </div>
        {:else if error}
          <div class='notice text-center'>
            <h2 class='font-weight-very-bold'>Could not load {year}</h2>
            <p class='text-muted'>{error}</p>
            <button type='button' class='btn btn-lg mt-10' use:click={() => load(year)}>Try again</button>
          </div>
        {:else if review && !review.stats.hasData}
          <div class='notice text-center'>
            <h2 class='font-weight-very-bold'>Nothing tracked in {review.year}</h2>
            <p class='text-muted'>No anime activity was found on your AniList account for this year.{years.length > 1 ? ' Pick another year above.' : ''}</p>
          </div>
          {#if review.local?.hasData}
            <ReviewContent {review} {account} localOnly />
          {/if}
        {:else if review}
          {#if review.stale}
            <div class='stale font-size-14 mb-15'>Could not refresh from AniList, showing the last saved data.</div>
          {/if}
          <ReviewContent {review} {account} />
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .year-review {
    inset: 0;
    z-index: 100;
    background:
      radial-gradient(120rem 60rem at 100% 0%, color-mix(in srgb, var(--accent-color) 12%, transparent), transparent 70%),
      #0e0f13;
    color: #fff;
  }
  .toolbar {
    gap: 0.8rem;
    /* Below the window controls / drag region of the title bar (28px) */
    padding: 3.6rem 2.4rem 1.2rem;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }
  .toolbar-title {
    font-size: 2.2rem;
  }
  .year-select {
    width: auto;
    min-width: 9rem;
    height: 3.6rem;
  }
  .tool-btn {
    height: 3.6rem;
    background: rgba(255, 255, 255, 0.07);
    border: 0;
  }
  .feedback {
    position: absolute;
    top: 9.2rem;
    right: 2.4rem;
    z-index: 2;
    padding: 0.8rem 1.4rem;
    border-radius: 1rem;
    background: #22252d;
    box-shadow: 0 0.4rem 2rem rgba(0, 0, 0, 0.4);
    max-width: calc(100% - 4.8rem);
    word-break: break-all;
  }
  .scroller {
    overflow-y: auto;
    overflow-x: hidden;
  }
  .content {
    max-width: 112rem;
    margin: 0 auto;
    padding: 2.4rem 2.4rem 6rem;
  }
  .notice {
    max-width: 56rem;
    margin: 8rem auto 2rem;
  }
  .progress-track {
    max-width: 40rem;
    height: 0.8rem;
    border-radius: 0.4rem;
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
  }
  .progress-fill {
    height: 100%;
    background: var(--accent-color);
    transition: width 0.3s ease;
  }
  .wait {
    color: var(--warning-color, #f5a524);
  }
  .stale {
    padding: 1rem 1.4rem;
    border-radius: 1.2rem;
    background: rgba(245, 165, 36, 0.12);
    color: #f5c46a;
  }
</style>
