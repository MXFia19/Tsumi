<script>
  import { CalendarClock } from 'lucide-svelte'
  import { isAlertable, movieDays } from '@/modules/moviealerts.js'
  import { upcomingReleases } from '@/modules/schedule/moviealerts.js'

  /** Theatrical and digital releases still to come of a TMDB movie, under the details buttons. */
  export let media

  let text = ''
  let loadedFor = null
  $: if (loadedFor !== (isAlertable(media) ? media.idTmdb : null)) load(media)

  async function load (target) {
    loadedFor = isAlertable(target) ? target.idTmdb : null
    text = ''
    if (!loadedFor) return
    const id = loadedFor
    const days = await movieDays(target).catch(() => null)
    if (loadedFor === id && days) text = upcomingReleases(days)
  }
</script>

{#if text}
  <div class='d-flex align-items-center text-muted font-size-14 mt-10'>
    <CalendarClock class='mr-5' size='1.6rem' />
    <span>{text}</span>
  </div>
{/if}
