<script>
  import { fly } from 'svelte/transition'
  import { click } from '@/modules/click.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { formatClock } from '@/routes/w2g/components/sync.js'
  import { Check, MonitorPlay, X } from 'lucide-svelte'

  /**
   * Watch Together prompts that need an answer: host requests (Accept / Decline, 15 s), invites
   * (Join / Dismiss), "Rejoin" after following again, and notices with an action.
   * Shown inside the open panel, or floating above the player while it is closed.
   */

  /** @type {import('./w2g.js').W2GClient} */
  export let client
  /** @type {import('./w2g.js').HostRequest[]} */
  export let requests = []
  /** @type {import('./w2g.js').Invite[]} */
  export let invites = []
  /** @type {{ media: any, episode: any, key: string } | null} */
  export let rejoin = null
  /** @type {{ id: number, text: string, action?: { label: string, run: () => void } | null }[]} */
  export let notices = []
  /** @type {(notice: any) => void} */
  export let dismissNotice = () => {}
  /** @type {{ name: string, media: any, episode: any, key: string } | null} v2.3 Join card (lobby is watching) */
  export let join = null
  /** @type {(() => void) | null} set to make the Join card dismissible */
  export let dismissJoin = null

  function requestText ({ name, kind, time }) {
    if (kind === 'pause') return `${name} wants to pause`
    if (kind === 'play') return `${name} wants to resume`
    return `${name} wants to jump to ${formatClock(time)}`
  }

  function mediaLabel ({ media, episode }) {
    return [anilistClient.title(media) || 'a title', client.episodeLabel(episode)].filter(Boolean).join(' · ')
  }

  /** Progress bar of a request prompt, set once so list updates don't restart it. */
  function timerBar (node, expiresAt) {
    node.style.animationDuration = `${Math.max(0, expiresAt - Date.now())}ms`
  }

  let rejoinHidden = false
  $: if (rejoin) rejoinHidden = false
</script>

{#each notices as notice (notice.id)}
  <div class='prompt bg-dark rounded p-10 mb-10 d-flex align-items-center flex-wrap' transition:fly={{ y: -10, duration: 150 }}>
    <span class='font-size-14 mr-10'>{notice.text}</span>
    {#if notice.action}
      <button type='button' class='btn btn-sm btn-primary ml-auto' use:click={() => { notice.action.run(); dismissNotice(notice) }}>{notice.action.label}</button>
    {/if}
  </div>
{/each}

{#if join}
  <div class='prompt bg-dark rounded p-10 mb-10' transition:fly={{ x: 30, duration: 150 }}>
    <div class='font-size-14 pb-5 text-break-word'>{join.name} is watching {mediaLabel(join)}</div>
    <div class='d-flex'>
      <button type='button' class='btn btn-sm btn-primary d-flex align-items-center' use:click={() => client.joinPlayback()}>
        <MonitorPlay size='1.4rem' class='mr-5' /> Join
      </button>
      {#if dismissJoin}
        <button type='button' class='btn btn-sm ml-10' use:click={dismissJoin}>Dismiss</button>
      {/if}
    </div>
  </div>
{/if}

{#each requests as request (request.id)}
  <div class='prompt bg-dark rounded p-10 mb-10 position-relative overflow-hidden' transition:fly={{ x: 30, duration: 150 }}>
    <div class='font-size-14 pb-5'>{requestText(request)}</div>
    <div class='d-flex'>
      <button type='button' class='btn btn-sm btn-primary d-flex align-items-center' use:click={() => client.answerRequest(request.id, true)}>
        <Check size='1.4rem' class='mr-5' /> Accept
      </button>
      <button type='button' class='btn btn-sm ml-10' use:click={() => client.answerRequest(request.id, false)}>Decline</button>
    </div>
    <div class='timer-bar' use:timerBar={request.expiresAt}></div>
  </div>
{/each}

{#each invites as invite (invite.from)}
  <div class='prompt bg-dark rounded p-10 mb-10' transition:fly={{ x: 30, duration: 150 }}>
    <div class='font-size-14 pb-5 text-break-word'>{invite.name} invites you to watch {mediaLabel(invite)}</div>
    <div class='d-flex'>
      <button type='button' class='btn btn-sm btn-primary d-flex align-items-center' use:click={() => client.joinInvite(invite.from)}>
        <MonitorPlay size='1.4rem' class='mr-5' /> Join
      </button>
      <button type='button' class='btn btn-sm ml-10' use:click={() => client.dismissInvite(invite.from)}>Dismiss</button>
    </div>
  </div>
{/each}

{#if rejoin && !rejoinHidden}
  <div class='prompt bg-dark rounded p-10 mb-10 d-flex align-items-center' transition:fly={{ x: 30, duration: 150 }}>
    <button type='button' class='btn btn-sm btn-primary d-flex align-items-center text-truncate' use:click={() => client.rejoin()}>
      <MonitorPlay size='1.4rem' class='mr-5 flex-shrink-0' /> <span class='text-truncate'>Rejoin {mediaLabel(rejoin)}</span>
    </button>
    <button type='button' class='btn btn-sm btn-square ml-10 d-flex align-items-center justify-content-center border-0 shadow-none flex-shrink-0' title='Hide' use:click={() => { rejoinHidden = true }}>
      <X size='1.4rem' />
    </button>
  </div>
{/if}

<style>
  .prompt {
    width: 100%;
    box-shadow: var(--dm-shadow);
    color: hsl(var(--white-color-hsl));
    pointer-events: all;
  }
  .timer-bar {
    position: absolute;
    left: 0;
    bottom: 0;
    height: 0.3rem;
    width: 100%;
    background: var(--accent-color);
    transform-origin: left;
    animation-name: shrink;
    animation-timing-function: linear;
    animation-fill-mode: forwards;
  }
  @keyframes shrink {
    from { transform: scaleX(1); }
    to { transform: scaleX(0); }
  }
</style>
