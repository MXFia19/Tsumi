<script>
  import SettingCard from '@/routes/settings/components/SettingCard.svelte'
  import ConfirmButton from '@/components/inputs/ConfirmButton.svelte'
  import { click } from '@/modules/click.js'
  import { toast } from 'svelte-sonner'
  import { traktStatus, traktLink, traktCancel, traktUnlink, traktOpenSignIn } from '@/modules/sync/trakt.js'
  import { pendingListUpdates, retryListUpdates, discardListUpdates } from '@/modules/sync/listqueue.js'

  export let settings

  // Cross-device resume and Trakt (common/modules/sync, Trakt account in electron/src/main/trakt.js).
  $: trakt = $traktStatus
  $: traktText = statusText(trakt)

  /** @param {import('@/modules/sync/trakt.js').TraktStatus} status */
  function statusText (status) {
    if (!status.available) return 'Trakt is not available in this build.'
    if (status.state === 'connected') return `Connected${status.user ? ` as ${status.user}` : ''}`
    if (status.state === 'linking') return 'Waiting for Trakt…'
    return 'Not connected'
  }

  // Episode progress not saved to the list yet (sync/listqueue.js: offline, or a list error), sent again on its own.
  $: pendingCount = $pendingListUpdates.length
  $: pendingError = [...$pendingListUpdates].reverse().find(entry => entry.error && entry.error !== 'offline')?.error
  let retrying = false
  async function retryPending () {
    if (retrying) return
    retrying = true
    try {
      const left = await retryListUpdates()
      if (left) toast.warning('List updates still pending', { description: `${left} ${left === 1 ? 'update' : 'updates'} could not be saved yet, ${left === 1 ? 'it is' : 'they are'} sent again later.` })
      else toast.success('List updates saved')
    } finally {
      retrying = false
    }
  }

  const positionDescription = 'Keeps the position of the episode you are watching in the note of its AniList entry (the comments on MyAnimeList), so you can stop on one device and resume at the same second on another one.\nTsumi only adds, updates and removes its own "[Tsumi]" line: the rest of your note is never changed. The line is removed once the episode is completed. Only for titles on your list.'
  // The notice is required by the Trakt API Use Policy.
  const traktDescription = 'Connect your Trakt account to scrobble the shows and movies you watch, and to resume them where you left off on another device.\nTsumi uses Trakt but is not endorsed or certified by Trakt.'
</script>

<h4 class='mb-10 font-weight-bold'>Sync Settings</h4>
{#if pendingCount}
  <SettingCard title='Pending List Updates' description={`Episode progress that could not be saved to your list yet (offline, or an AniList / MyAnimeList error). It is sent again when the connection comes back and every 10 minutes.${pendingError ? `\nLast error: ${pendingError}` : ''}`}>
    <div class='d-flex flex-column align-items-md-end mw-full'>
      <div class='font-weight-semi-bold text-truncate mw-full mb-5'>{pendingCount} list {pendingCount === 1 ? 'update' : 'updates'} pending</div>
      <div class='d-flex'>
        <button type='button' use:click={retryPending} disabled={retrying} class='btn btn-primary d-flex align-items-center justify-content-center mr-10'><span class='text-truncate'>{retrying ? 'Retrying…' : 'Retry'}</span></button>
        <ConfirmButton click={() => discardListUpdates()} class='btn btn-danger d-flex align-items-center justify-content-center' confirmText='Confirm Discard' confirmClass='btn-danger-dim long-button' cancelClass='btn-secondary long-button' actionClass='d-inline-flex' dataToggle='tooltip' dataPlacement='top' dataTitle='Forgets These Updates: Your List Keeps Its Current Progress'>
          <span class='text-truncate'>Discard</span>
        </ConfirmButton>
      </div>
    </div>
  </SettingCard>
{/if}
<SettingCard title='Sync playback position across devices' description={positionDescription}>
  <div class='custom-switch'>
    <input type='checkbox' id='sync-playback-position' bind:checked={settings.syncPlaybackPosition} />
    <label for='sync-playback-position'>{settings.syncPlaybackPosition ? 'On' : 'Off'}</label>
  </div>
</SettingCard>
<SettingCard title='Trakt' description={traktDescription}>
  <div class='d-flex flex-column align-items-md-end mw-full'>
    <div class='font-weight-semi-bold text-truncate mw-full mb-5' title={traktText}>{traktText}</div>
    {#if trakt.available}
      {#if trakt.state === 'linking'}
        <div class='text-muted mb-5 text-md-right'>Sign in to Trakt and allow Tsumi in your browser, then come back here.</div>
        <div class='d-flex'>
          <button type='button' use:click={traktOpenSignIn} class='btn btn-primary d-flex align-items-center justify-content-center mr-10'><span class='text-truncate'>Open Trakt again</span></button>
          <button type='button' use:click={traktCancel} class='btn btn-danger d-flex align-items-center justify-content-center'><span class='text-truncate'>Cancel</span></button>
        </div>
      {:else if trakt.state === 'connected'}
        <button type='button' use:click={traktUnlink} class='btn btn-danger d-flex align-items-center justify-content-center'><span class='text-truncate'>Disconnect</span></button>
      {:else}
        <button type='button' use:click={traktLink} class='btn btn-primary d-flex align-items-center justify-content-center'><span class='text-truncate'>Connect</span></button>
      {/if}
      {#if trakt.error}
        <div class='text-danger font-size-12 mt-5 pre-wrap text-md-right'>{trakt.error}</div>
      {/if}
    {/if}
  </div>
</SettingCard>
{#if trakt.available && trakt.state === 'connected'}
  <SettingCard title='Scrobble to Trakt' description='Tells Trakt what you are watching (shows and movies): it shows "watching now" on your profile, marks them watched past 80%, and saves your progress when you pause or leave the player.'>
    <div class='custom-switch'>
      <input type='checkbox' id='trakt-scrobble' bind:checked={settings.traktScrobble} />
      <label for='trakt-scrobble'>{settings.traktScrobble ? 'On' : 'Off'}</label>
    </div>
  </SettingCard>
  <SettingCard title='Scrobble Anime to Trakt' description='Also scrobbles anime, matched to their Trakt show and episode through the TVDB / TMDB mappings of ani.zip. Some anime have no mapping or a different episode numbering and are skipped.'>
    <div class='custom-switch'>
      <input type='checkbox' id='trakt-scrobble-anime' bind:checked={settings.traktScrobbleAnime} disabled={!settings.traktScrobble} />
      <label for='trakt-scrobble-anime'>{settings.traktScrobbleAnime ? 'On' : 'Off'}</label>
    </div>
  </SettingCard>
{/if}
