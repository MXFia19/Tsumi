<script>
  import { toast } from 'svelte-sonner'
  import { click } from '@/modules/click.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { queueItemLabel, episodeLabelFor } from '@/routes/w2g/components/sync.js'
  import { queueResultText } from '@/routes/w2g/components/session.js'
  import { ListVideo, ListPlus, ThumbsUp, ChevronUp, ChevronDown, Play, X, Check } from 'lucide-svelte'

  /**
   * v2.4 shared queue ("Up next"), on the lobby page and in the player panel: items with votes and the host tools,
   * suggestions waiting for approval, "Members need approval" and "Add next episode".
   */

  /** @type {import('./w2g.js').W2GClient} */
  export let client

  /** Smaller rows, for the player panel. */
  export let compact = false

  $: queue = client.queue
  $: lobby = client.lobby
  $: peers = client.peers
  $: following = client.following
  $: isHost = $lobby.hostId != null && String($lobby.hostId) === client.selfId
  // The stores are passed so the values are recomputed whenever one of them changes.
  function available (client, ..._stores) {
    return client.queueAvailable
  }
  function nextOffer (client, ..._stores) {
    return client.nextEpisodeOffer()
  }
  $: shown = available(client, $lobby, $peers)
  $: next = nextOffer(client, $queue, $lobby, $peers)
  $: nextLabel = next ? episodeLabelFor({ episode: next.episode, format: next.media?.format, episodes: next.media?.episodes }) : ''

  function addNext () {
    const result = client.addNextEpisode(anilistClient.title(next.media))
    toast('Watch Together', { description: queueResultText(result) })
  }

  function addedBy (item) {
    return String(item.addedBy) === client.selfId ? 'you' : (item.addedByName || 'someone')
  }

  function mine (item) {
    return String(item.addedBy) === client.selfId
  }
</script>

{#if shown}
  <div class='w2g-queue' class:compact>
    <div class='d-flex align-items-center flex-wrap pb-5'>
      <ListVideo size='1.6rem' class='mr-5' />
      <span class='font-weight-bold' class:font-size-18={!compact} class:font-size-16={compact}>Up next ({$queue.items.length})</span>
      {#if next}
        <button type='button' class='btn btn-sm d-flex align-items-center ml-auto my-5' title='Queue the episode after the lobby one' use:click={addNext}>
          <ListPlus size='1.4rem' class='mr-5' /> Add {nextLabel || 'next episode'}
        </button>
      {/if}
    </div>
    {#if isHost}
      <div class='custom-switch mb-5' title='Members suggest, you accept or decline'>
        <input type='checkbox' id='w2g-queue-approval-{compact ? 'panel' : 'lobby'}' checked={$queue.policy === 'approval'} on:change={({ target }) => client.setQueuePolicy(target.checked ? 'approval' : 'open')} />
        <label for='w2g-queue-approval-{compact ? 'panel' : 'lobby'}' class='font-size-14'>Members need approval</label>
      </div>
    {/if}
    {#each $queue.items as item, index (item.id)}
      <div class='item d-flex align-items-center py-5'>
        {#if item.cover}
          <img src={item.cover} alt='' class='cover rounded flex-shrink-0' loading='lazy' />
        {:else}
          <div class='cover rounded flex-shrink-0 bg-dark-light'></div>
        {/if}
        <div class='d-flex flex-column overflow-hidden flex-grow-1 px-10'>
          <span class='text-truncate font-size-14' title={queueItemLabel(item)}>{queueItemLabel(item)}</span>
          <span class='text-muted text-truncate font-size-12'>Added by {addedBy(item)}</span>
        </div>
        <button type='button' class='btn btn-sm d-flex align-items-center action flex-shrink-0' class:voted={item.votes.includes(client.selfId)}
          title={item.votes.includes(client.selfId) ? 'Remove your vote' : 'Vote for it'} aria-label='Vote for {queueItemLabel(item)}' use:click={() => client.voteQueueItem(item.id)}>
          <ThumbsUp size='1.3rem' />{#if item.votes.length}<span class='ml-5 font-size-12'>{item.votes.length}</span>{/if}
        </button>
        {#if isHost}
          <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0 ml-5' disabled={index === 0} title='Move up' aria-label='Move {queueItemLabel(item)} up' use:click={() => client.moveQueueItem(item.id, -1)}>
            <ChevronUp size='1.4rem' />
          </button>
          <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0 ml-5' disabled={index === $queue.items.length - 1} title='Move down' aria-label='Move {queueItemLabel(item)} down' use:click={() => client.moveQueueItem(item.id, 1)}>
            <ChevronDown size='1.4rem' />
          </button>
          {#if $following}
            <button type='button' class='btn btn-sm btn-primary d-flex align-items-center justify-content-center action flex-shrink-0 ml-5' title='Play now for everyone' aria-label='Play {queueItemLabel(item)} now' use:click={() => client.playQueueItem(item.id)}>
              <Play size='1.4rem' />
            </button>
          {/if}
        {/if}
        {#if isHost || mine(item)}
          <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0 ml-5 text-danger' title='Remove' aria-label='Remove {queueItemLabel(item)}' use:click={() => client.removeQueueItem(item.id)}>
            <X size='1.4rem' />
          </button>
        {/if}
      </div>
    {:else}
      <div class='text-muted font-size-12 py-5'>Nothing queued. Add episodes from their details page.</div>
    {/each}
    {#if $queue.pending.length}
      <div class='text-muted font-size-12 pt-10 pb-5'>Waiting for the host's approval</div>
      {#each $queue.pending as item (item.id)}
        <div class='item d-flex align-items-center py-5 pending'>
          <div class='d-flex flex-column overflow-hidden flex-grow-1 pr-10'>
            <span class='text-truncate font-size-14' title={queueItemLabel(item)}>{queueItemLabel(item)}</span>
            <span class='text-muted text-truncate font-size-12'>Suggested by {addedBy(item)}</span>
          </div>
          {#if isHost}
            <button type='button' class='btn btn-sm btn-primary d-flex align-items-center justify-content-center action flex-shrink-0' title='Accept' aria-label='Accept {queueItemLabel(item)}' use:click={() => client.answerSuggestion(item.id, true)}>
              <Check size='1.4rem' />
            </button>
            <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0 ml-5' title='Decline' aria-label='Decline {queueItemLabel(item)}' use:click={() => client.answerSuggestion(item.id, false)}>
              <X size='1.4rem' />
            </button>
          {:else if mine(item)}
            <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0' title='Cancel your suggestion' aria-label='Cancel {queueItemLabel(item)}' use:click={() => client.removeQueueItem(item.id)}>
              <X size='1.4rem' />
            </button>
          {/if}
        </div>
      {/each}
    {/if}
  </div>
{/if}

<style>
  .cover {
    width: 3.6rem;
    height: 5rem;
    object-fit: cover;
  }
  .compact .cover {
    width: 2.9rem;
    height: 4rem;
  }
  .action {
    min-width: 3.2rem;
    height: 3.2rem;
    padding: 0 0.6rem;
  }
  .action.voted {
    background: hsla(var(--completed-hsl), 0.25);
    color: var(--completed-color);
  }
  .item + .item {
    border-top: 1px solid hsla(var(--white-color-hsl), 0.06);
  }
  .pending {
    opacity: 0.85;
  }
</style>
