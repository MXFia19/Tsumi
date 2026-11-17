<script>
  import { onDestroy } from 'svelte'
  import { click } from '@/modules/click.js'
  import { IPC } from '@/modules/bridge.js'
  import { ExternalLink, Crown, UserX, MonitorPlay, Headphones, MicOff, Volume2, VolumeX } from 'lucide-svelte'
  import { memberName, nowPlayingLabel } from '@/routes/w2g/components/sync.js'

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

  /** @type {((userId: string) => void) | null} "Invite to watch", shown when member.canInvite */
  export let onInvite = null

  /** v2.4: we are in voice, so a member in voice gets its mute / volume menu. */
  export let voiceJoined = false

  /** @type {((userId: string, mix: { muted?: boolean, volume?: number }) => void) | null} local mute / volume of a member */
  export let onVoiceMix = null

  $: inVoice = !!member?.voice?.joined
  $: speaking = inVoice && !!member?.voice?.speaking
  $: canMix = voiceJoined && inVoice && !member?.isSelf && !!onVoiceMix
  let mixOpen = false
  $: if (!canMix) mixOpen = false

  // What the member watches: "Title · Episode 5 · Extension · Server".
  $: watching = member ? [nowPlayingLabel(member.nowPlaying), member.source].filter(Boolean).join(' · ') : ''
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
  <img src={avatar} alt='ProfilePicture' class='avatar rounded-circle p-5 flex-shrink-0' class:speaking title={speaking ? `${member?.name} is speaking` : ''} />
  <div class='d-flex flex-column pl-5 overflow-hidden flex-grow-1'>
    <div class='d-flex align-items-center line-height-normal' class:font-size-18={!compact} class:font-size-14={compact}>
      {#if member?.isHost}
        <span class='crown d-flex align-items-center mr-5 flex-shrink-0' title='Host'>
          <Crown size={compact ? '1.4rem' : '1.7rem'} strokeWidth={2.5} />
        </span>
      {/if}
      <span class='text-truncate'>{name}</span>
      {#if inVoice}
        <span class='voice-mark d-flex align-items-center ml-5 flex-shrink-0' class:live={speaking} title={member.voice.muted ? 'In voice, muted' : 'In voice'}>
          {#if member.voice.muted}<MicOff size='1.3rem' />{:else}<Headphones size='1.3rem' />{/if}
        </span>
        {#if member.voice.localMuted}
          <span class='voice-mark d-flex align-items-center ml-5 flex-shrink-0 text-danger' title='Muted for you'><VolumeX size='1.3rem' /></span>
        {/if}
      {/if}
    </div>
    {#if watching}
      <div class='text-muted text-truncate line-height-normal watching' class:font-size-12={compact} class:font-size-14={!compact} title={watching}>{watching}</div>
    {/if}
    {#if member?.badge}
      <div class='d-flex mt-5'>
        <span class='w2g-badge text-nowrap' data-kind={member.badge.kind} title={member.rtt != null ? `Ping ${Math.round(member.rtt)} ms` : ''}>{member.badge.text}</span>
      </div>
    {/if}
    {#if mixOpen && canMix}
      <div class='d-flex align-items-center mt-5 voice-mix'>
        <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0' class:confirm={member.voice.localMuted}
          title={member.voice.localMuted ? `Unmute ${member.name} for you` : `Mute ${member.name} for you`} use:click={() => onVoiceMix(member.userId, { muted: !member.voice.localMuted })}>
          {#if member.voice.localMuted}<VolumeX size='1.4rem' />{:else}<Volume2 size='1.4rem' />{/if}
        </button>
        <input class='custom-range ml-10 flex-grow-1' type='range' min='0' max='1' step='0.05' value={member.voice.volume ?? 1}
          aria-label='Volume of {member.name}' on:input={({ target }) => onVoiceMix(member.userId, { volume: Number(target.value) })} />
        <span class='font-size-12 text-muted ml-5 text-nowrap'>{Math.round((member.voice.volume ?? 1) * 100)}%</span>
      </div>
    {/if}
  </div>
  {#if canMix}
    <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0 ml-5' class:active={mixOpen}
      title='Volume of {member.name}' aria-label='Volume of {member.name}' use:click={() => { mixOpen = !mixOpen }}>
      {#if member.voice.localMuted}<VolumeX size='1.6rem' />{:else}<Volume2 size='1.6rem' />{/if}
    </button>
  {/if}
  {#if member?.canInvite && onInvite}
    <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center action flex-shrink-0 ml-5'
      title='Invite to watch' aria-label='Invite {member.name} to watch' use:click={() => onInvite(member.userId)}>
      <MonitorPlay size='1.6rem' />{#if !compact}<span class='ml-5 font-size-12 text-nowrap'>Invite to watch</span>{/if}
    </button>
  {/if}
  {#if canManage && member && !member.isSelf}
    <div class='d-flex align-items-center flex-shrink-0 ml-5'>
      <!-- A v1 client cannot act as host (mode, kick, requests), nor a channel that copied another member's ids (v2.6). -->
      {#if member.protocol >= 2 && !member.shadow}
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
  .avatar.speaking {
    box-shadow: 0 0 0 0.25rem var(--completed-color);
  }
  .voice-mark {
    color: hsla(var(--white-color-hsl), 0.7);
  }
  .voice-mark.live {
    color: var(--completed-color);
  }
  .action.active {
    background: hsla(var(--white-color-hsl), 0.15);
  }
  .voice-mix {
    max-width: 24rem;
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
  .w2g-badge[data-kind='speed'],
  .w2g-badge[data-kind='other'] {
    background: hsla(var(--warning-color-hsl), 0.2);
    color: var(--warning-color);
  }
  .w2g-badge[data-kind='nosignal'],
  .w2g-badge[data-kind='old'] {
    background: hsla(var(--error-color-very-light-hsl), 0.35);
    color: hsla(var(--white-color-hsl), 0.85);
  }
  .w2g-badge[data-kind='own'] {
    background: hsla(209, 80%, 60%, 0.2);
    color: hsl(209, 90%, 75%);
  }
  .watching {
    max-width: 100%;
  }
</style>
