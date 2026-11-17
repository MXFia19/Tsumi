<script>
  import { Bell, BellRing } from 'lucide-svelte'
  import { toast } from 'svelte-sonner'
  import { click } from '@/modules/click.js'
  import { movieAlerts, isAlertable, movieDays, toggleMovieAlert } from '@/modules/moviealerts.js'
  import { canAlert, upcomingReleases } from '@/modules/schedule/moviealerts.js'

  /** Release alert of a TMDB movie (modules/moviealerts.js): shown until the movie is out on digital. */
  export let media

  let days = null
  let loadedFor = null
  $: if (isAlertable(media) && loadedFor !== media.idTmdb) load(media)

  async function load (target) {
    loadedFor = target.idTmdb
    days = null
    const found = await movieDays(target).catch(() => null)
    if (loadedFor === target.idTmdb) days = found
  }

  $: on = $movieAlerts.some(alert => alert.idTmdb === media?.idTmdb)
  // Hidden once on digital, or out in theaters for over 6 months with no digital date (canAlert), except to turn
  // off an alert still on.
  $: shown = isAlertable(media) && days && (on || canAlert(days))
  $: upcoming = days ? upcomingReleases(days) : ''
  $: tip = on ? 'Turn off the release alert' : `Notify me when it comes out${upcoming ? ` (${upcoming})` : ''}`

  function toggle () {
    if (toggleMovieAlert(media)) toast.success('Release alert on', { description: upcoming || 'You will be notified when it comes out in theaters and on digital.' })
    else toast('Release alert off')
  }
</script>

{#if shown}
  <button
    class='btn bg-dark-light btn-lg btn-square d-flex align-items-center justify-content-center shadow-none border-0 mr-10'
    data-toggle='tooltip'
    data-placement='top'
    data-target-breakpoint='md'
    data-title={tip}
    title={tip}
    aria-label={on ? 'Turn off the release alert' : 'Turn on the release alert'}
    aria-pressed={on}
    use:click={toggle}
  >
    {#if on}
      <BellRing size='1.7rem' color='var(--tertiary-color)' />
    {:else}
      <Bell size='1.7rem' />
    {/if}
  </button>
{/if}
