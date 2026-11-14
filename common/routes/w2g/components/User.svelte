<script>
  import { onDestroy } from 'svelte'
  import { click } from '@/modules/click.js'
  import { IPC } from '@/modules/bridge.js'
  import { ExternalLink, Crown, UserX } from 'lucide-svelte'
  import { memberName } from '@/routes/w2g/components/sync.js'

  /** @type {any} participant (v1 usage, without `member`) */
  export let user = {}

  /** @type {import('./w2g.js').MemberView | null} member with host crown and sync badge */
  export let member = null

  /** Show the host actions (transfer, kick) for this member. */
  export let canManage = false

  /** Smaller row, for the player panel. */
  export let compact = false

  /** @type {((userId: string) => void) | null} */
  export let onKick = null

  /** @type {((userId: string) => void) | null} */
  export let onTransfer = null

  $: shown = member?.user ?? user
  $: name = member ? member.name + (member.isSelf ? ' (you)' : '') : memberName(shown)
  $: avatar = shown?.avatar?.medium || shown?.picture || 'https://s4.anilist.co/file/anilistcdn/user/avatar/large/default.png'
  $: profile = shown?.name && (shown?.avatar?.medium || shown?.picture)
    ? (shown?.avatar?.medium ? 'https://anilist.co/user/' : 'https://myanimelist.net/profile/') + shown.name
    : null

  // Host actions need a second tap, so a mis-tap on a phone does not remove anyone.
  /** @type {'kick' | 'host' | null} */
  let confirming = null
  let confirmTimer
  function confirm (kind, run) {
    clearTimeout(confirmTimer)
    if (confirming === kind) {
      confirming = null
      run()
      return
    }
    confirming = kind
    confirmTimer = setTimeout(() => { confirming = null }, 3000)
  }
  onDestroy(() => clearTimeout(confirmTimer))
</script>

<div class='d-flex align-items-center member' class:pb-10={!compact} class:py-5={compact} class:compact>
  <img src={avatar} alt='ProfilePicture' class='avatar rounded-circle p-5 flex-shrink-0' />
  <div class='d-flex flex-column pl-5 overflow-hidden flex-grow-1'>
    <div class='d-flex align-items-center line-height-normal' class:font-size-18={!compact} class:font-size-14={compact}>
      {#if member?.isHost}
        <span class='crown d-flex align-items-center mr-5 flex-shrink-0' title='Host'>
          <Crown size={compact ? '1.4rem' : '1.7rem'} strokeWidth={2.5} />
        </span>
      {/if}
      <span class='text-truncate'>{name}</span>
    </div>
    {#if member?.badge}
      <div class='d-flex mt-5'>
        <span class='w2g-badge text-nowrap' data-kind={member.badge.kind} title={member.rtt != null ? `Ping ${Math.round(member.rtt)} ms` : ''}>{member.badge.text}</span>
      </div>
    {/if}
  </div>
  {#if canManage && member && !member.isSelf}
    <div class='d-flex align-items-center flex-shrink-0 ml-5'>
      <!-- A v1 client cannot act as host (mode, kick, requests). -->
      {#if member.protocol >= 2}
        <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action' class:confirm={confirming === 'host'}
          title='Make host' aria-label='Make {member.name} the host' use:click={() => confirm('host', () => onTransfer?.(member.userId))}>
          {#if confirming === 'host'}<span class='px-5 font-size-12'>Make host?</span>{:else}<Crown size='1.6rem' />{/if}
        </button>
      {/if}
      <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action ml-5 text-danger' class:confirm={confirming === 'kick'}
        title='Remove from the lobby' aria-label='Remove {member.name} from the lobby' use:click={() => confirm('kick', () => onKick?.(member.userId))}>
        {#if confirming === 'kick'}<span class='px-5 font-size-12'>Remove?</span>{:else}<UserX size='1.6rem' />{/if}
      </button>
    </div>
  {:else if profile && !compact}
    <span class='pointer text-primary d-flex align-items-center ml-auto' title='Open profile' use:click={() => IPC.emit('open', profile)}>
      <ExternalLink size='2rem' />
    </span>
  {/if}
</div>

<style>
  .avatar {
    width: 5rem;
    height: 5rem;
  }
  .compact .avatar {
    width: 3.8rem;
    height: 3.8rem;
  }
  .crown {
    color: #F5C542;
  }
  .action {
    min-width: 3.6rem;
    height: 3.6rem;
    padding: 0 0.6rem;
  }
  .action.confirm {
    background: var(--error-color-light);
    color: hsl(var(--white-color-hsl)) !important;
  }
  .w2g-badge {
    font-size: 1.15rem;
    line-height: 1.7rem;
    padding: 0 0.7rem;
    border-radius: 1rem;
    background: hsla(var(--white-color-hsl), 0.1);
    color: hsla(var(--white-color-hsl), 0.75);
  }
  .w2g-badge[data-kind='sync'] {
    background: hsla(var(--completed-hsl), 0.18);
    color: var(--completed-color);
  }
  .w2g-badge[data-kind='ahead'],
  .w2g-badge[data-kind='behind'],
  .w2g-badge[data-kind='other'] {
    background: hsla(var(--warning-color-hsl), 0.2);
    color: var(--warning-color);
  }
  .w2g-badge[data-kind='nosignal'],
  .w2g-badge[data-kind='old'] {
    background: hsla(var(--error-color-very-light-hsl), 0.35);
    color: hsla(var(--white-color-hsl), 0.85);
  }
</style>
