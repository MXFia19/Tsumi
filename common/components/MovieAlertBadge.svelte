<script>
  import { BellRing } from 'lucide-svelte'
  import { movieAlerts, isAlertable } from '@/modules/moviealerts.js'

  /** Bell on the cover of a schedule movie whose release alert is on (modules/moviealerts.js). */
  export let media

  $: on = isAlertable(media) && $movieAlerts.some(alert => alert.idTmdb === media.idTmdb)
</script>

{#if on}
  <span class='movie-alert-badge position-absolute d-flex align-items-center justify-content-center bg-dark rounded-circle' title='Release alert on' aria-label='Release alert on'>
    <BellRing size='1.5rem' color='var(--tertiary-color)' />
  </span>
{/if}

<style>
  .movie-alert-badge {
    right: .6rem;
    bottom: .6rem;
    width: 2.8rem;
    height: 2.8rem;
    z-index: 1;
    box-shadow: 0 .2rem .5rem hsla(var(--black-color-hsl), 0.4);
  }
</style>
