<script>
  // Home banner of the Year in Review, shown in December (this year) and January (last year) to AniList users.
  import { bannerYear } from '@/modules/yearreview/stats.js'
  import { openYearReview, reviewAccount } from '@/modules/yearreview/yearreview.js'
  import { click } from '@/modules/click.js'
  import { Sparkles, X } from 'lucide-svelte'

  const DISMISS_KEY = 'yearReviewBannerDismissed'
  const year = bannerYear()
  const december = new Date().getMonth() === 11
  let dismissed = false
  try { dismissed = Number(localStorage.getItem(DISMISS_KEY)) === year } catch {}
  const visible = !!year && reviewAccount().kind === 'anilist'

  function dismiss () {
    dismissed = true
    try { localStorage.setItem(DISMISS_KEY, String(year)) } catch {}
  }
</script>

{#if visible && !dismissed}
  <div class='yr-banner d-flex align-items-center mb-20 mr-20 mr-md-30' role='region' aria-label='Year in Review'>
    <div class='yr-icon d-flex align-items-center justify-content-center flex-shrink-0'><Sparkles size='2.2rem' /></div>
    <div class='flex-grow-1 min-w-0 mx-15'>
      <div class='font-weight-bold font-size-16'>{december ? `Your ${year} in anime so far` : `Your ${year} in anime`}</div>
      <div class='text-muted font-size-13 text-truncate'>Episodes, hours, top anime, genres and studios of your year on AniList.</div>
    </div>
    <button type='button' class='btn yr-open flex-shrink-0' use:click={() => openYearReview(year)}>See your year</button>
    <button type='button' class='btn btn-square yr-close flex-shrink-0 ml-5 d-flex align-items-center justify-content-center' title='Hide until next year' use:click={dismiss}><X size='1.8rem' /></button>
  </div>
{/if}

<style>
  .yr-banner {
    padding: 1.2rem 1.4rem;
    border-radius: 1.6rem;
    background:
      linear-gradient(90deg, color-mix(in srgb, var(--accent-color) 16%, transparent), transparent 70%),
      var(--dark-color-light);
  }
  .yr-icon {
    width: 4.2rem;
    height: 4.2rem;
    border-radius: 50%;
    background: var(--accent-color);
    color: var(--dark-color);
  }
  .min-w-0 {
    min-width: 0;
  }
  .yr-open {
    background: var(--accent-color);
    color: var(--dark-color);
    font-weight: 700;
    border: 0;
  }
  .yr-close {
    background: transparent;
    border: 0;
  }
</style>
