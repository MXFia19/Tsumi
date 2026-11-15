<script>
  // Shown over the (paused) local video while casting.
  import { Cast } from 'lucide-svelte'
  import { castState } from '@/modules/cast.js'

  export let miniplayer = false

  $: state = $castState
  $: label = statusLabel(state)

  function statusLabel (state) {
    if (state.phase === 'connecting') return 'Connecting…'
    if (state.phase === 'loading') return 'Loading…'
    if (state.idleReason === 'FINISHED') return 'Finished'
    switch (state.playerState) {
      case 'PLAYING': return 'Playing'
      case 'PAUSED': return 'Paused'
      case 'BUFFERING': return 'Buffering…'
      default: return ''
    }
  }
</script>

{#if state.active}
  <div class='cast-overlay position-absolute w-full h-full d-flex flex-column align-items-center justify-content-center text-white' class:mini={miniplayer}>
    <Cast size={miniplayer ? '2.4rem' : '5rem'} strokeWidth={1.5} />
    <div class='name font-weight-bold mt-10 text-center px-20 text-truncate mw-full'>Casting to {state.device?.name || 'a Cast device'}</div>
    {#if label && !miniplayer}<div class='text-muted mt-5'>{label}</div>{/if}
  </div>
{/if}

<style>
  .cast-overlay {
    top: 0;
    left: 0;
    background: rgba(0, 0, 0, 0.88);
    pointer-events: none;
  }
  .name {
    font-size: 2rem;
  }
  .mini .name {
    font-size: 1.3rem;
  }
</style>
