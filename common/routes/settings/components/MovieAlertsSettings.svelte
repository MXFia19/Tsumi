<script>
  import SettingCard from '@/routes/settings/components/SettingCard.svelte'
  import { click } from '@/modules/click.js'
  import { Trash2 } from 'lucide-svelte'
  import { movieAlerts, toggleMovieAlert } from '@/modules/moviealerts.js'

  // The movies with a release alert on (modules/moviealerts.js, the bell of the movie details), to review and remove
  // them without opening each movie.
  const description = 'Movies you are notified about when they come out in theaters, then on digital. Turn one on with the bell of a movie\'s details. An alert ends once the movie is out on digital.'

  /** @param {import('@/modules/moviealerts.js').MovieAlert} alert */
  function remove (alert) {
    // The alert's media snapshot, with what toggleMovieAlert needs to find it.
    toggleMovieAlert({ ...(alert.media || {}), id: alert.id, idTmdb: alert.idTmdb, isTmdb: true, format: 'MOVIE' })
  }
</script>

<SettingCard title='Release Alerts' {description}>
  <div class='d-flex flex-column w-300 mw-full'>
    {#each $movieAlerts as alert (`${alert.idTmdb}:${alert.addedAt}`)}
      <div class='d-flex align-items-center mb-10'>
        <div class='flex-grow-1 overflow-hidden mr-10'>
          <div class='text-truncate font-weight-semi-bold' title={alert.title}>{alert.title}</div>
          <div class='text-muted font-size-12 text-truncate'>{alert.notified?.includes('theatrical') ? 'In theaters, waiting for digital' : 'Waiting for its release'}</div>
        </div>
        <button type='button' use:click={() => remove(alert)} class='btn btn-danger btn-square px-5 d-flex align-items-center flex-shrink-0' title='Remove the release alert' aria-label={`Remove the release alert of ${alert.title}`}><Trash2 size='1.8rem' /></button>
      </div>
    {:else}
      <div class='text-muted'>No release alert</div>
    {/each}
  </div>
</SettingCard>
