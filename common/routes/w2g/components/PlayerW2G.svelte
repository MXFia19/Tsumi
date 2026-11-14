<script>
  import { onDestroy, tick } from 'svelte'
  import { readable } from 'svelte/store'
  import { fade, fly } from 'svelte/transition'
  import { click } from '@/modules/click.js'
  import { state } from '@/routes/w2g/components/session.js'
  import User from '@/routes/w2g/components/User.svelte'
  import Prompts from '@/routes/w2g/components/Prompts.svelte'
  import { REACTIONS, BUBBLE_MS, NOTICE_MS, memberName, formatClock } from '@/routes/w2g/components/sync.js'
  import { Users, X, SendHorizontal, Crown, RefreshCw, Timer, Hand, DoorOpen } from 'lucide-svelte'

  /** @type {import('./w2g.js').W2GClient} */
  export let client

  /** The player controls are hidden: hide the button with them. */
  export let immersed = false

  let open = false
  let unread = 0
  let text = ''
  /** @type {HTMLElement} */
  let chatBox
  /** @type {{ id: number, name: string, message: string }[]} */
  let bubbles = []
  /** @type {{ id: number, text: string, action?: { label: string, run: () => void } | null }[]} */
  let notices = []
  /** @type {{ id: number, emoji: string, right: number }[]} */
  let floats = []
  let nextId = 0
  let confirmLeave = false

  const timers = new Set()
  function later (fn, ms) {
    const timer = setTimeout(() => {
      timers.delete(timer)
      fn()
    }, ms)
    timers.add(timer)
  }

  // Sync badges age with time.
  const clock = readable(Date.now(), set => {
    const interval = setInterval(() => set(Date.now()), 1000)
    return () => clearInterval(interval)
  })

  $: lobby = client.lobby
  $: peers = client.peers
  $: signals = client.signals
  $: localStatus = client.localStatus
  $: messages = client.messages
  $: requests = client.requests
  $: invites = client.invites
  $: following = client.following
  $: rejoinOffer = client.rejoinOffer
  $: countdown = client.countdown

  // The stores are passed so the values are recomputed whenever one of them changes.
  function listMembers (client, now, ..._stores) {
    return client.describeMembers(now)
  }
  function readHostPaused (client, ..._stores) {
    return client.hostPaused()
  }
  $: members = open ? listMembers(client, $clock, $peers, $lobby, $signals, $localStatus) : []
  $: isHost = $lobby.hostId != null && String($lobby.hostId) === client.selfId
  $: hostMode = $lobby.hostId != null && $lobby.mode === 'host'
  $: locked = hostMode && !isHost && $following
  $: canCountdown = $following && (isHost || !hostMode)
  $: hostPaused = open && locked ? readHostPaused(client, $clock, $signals) : false
  $: watching = $localStatus.state !== 'idle'
  $: chat = open ? $messages.slice(-100) : []
  $: if (open && chat.length) scrollChat()

  async function scrollChat () {
    await tick()
    if (chatBox) chatBox.scrollTop = chatBox.scrollHeight
  }

  // ---- client events
  let detach = null
  $: attach(client)
  function attach (target) {
    detach?.()
    detach = null
    if (!target) return
    const handlers = { chat: onChat, notice: onNotice, info: onInfo, blocked: onBlocked, reaction: onReaction }
    for (const [event, handler] of Object.entries(handlers)) target.on(event, handler)
    detach = () => {
      for (const [event, handler] of Object.entries(handlers)) target.off(event, handler)
    }
  }

  function onChat ({ name, message }) {
    if (open) return
    unread += 1
    const bubble = { id: ++nextId, name, message: message.length > 160 ? message.slice(0, 160) + '…' : message }
    bubbles = [...bubbles.slice(-2), bubble]
    later(() => { bubbles = bubbles.filter(item => item !== bubble) }, BUBBLE_MS)
  }

  function notify (text, action = null, ms = NOTICE_MS) {
    const notice = { id: ++nextId, text, action }
    // Only one "Only the host controls playback" at a time.
    notices = [...notices.filter(item => !(action && item.action)).slice(-2), notice]
    later(() => dismiss(notice), ms)
  }

  function dismiss (notice) {
    notices = notices.filter(item => item !== notice)
  }

  function onNotice ({ text }) {
    // The open panel's chat already shows it.
    if (open) return
    notify(text)
  }

  function onInfo ({ text }) {
    notify(text)
  }

  function onBlocked ({ action, time }) {
    const kind = action === 'seek' ? 'seek' : action === 'pause' ? 'pause' : 'play'
    const label = kind === 'seek' ? `Request jump to ${formatClock(time)}` : kind === 'pause' ? 'Request pause' : 'Request play'
    notify('Only the host controls playback', { label, run: () => client.request(kind, time) }, 5000)
  }

  function onReaction ({ emoji }) {
    const float = { id: ++nextId, emoji, right: 4 + Math.random() * 14 }
    floats = [...floats.slice(-11), float]
    later(() => { floats = floats.filter(item => item !== float) }, 2600)
  }

  // ---- countdown overlay
  let countdownLeft = 0
  let countdownTimer
  $: runCountdown($countdown)
  function runCountdown (value) {
    clearInterval(countdownTimer)
    countdownLeft = 0
    if (!value) return
    const update = () => {
      countdownLeft = Math.max(0, Math.ceil((value.endsAt - Date.now()) / 1000))
      if (!countdownLeft) clearInterval(countdownTimer)
    }
    update()
    countdownTimer = setInterval(update, 100)
  }

  // ---- actions
  function toggle () {
    open = !open
    if (open) {
      unread = 0
      bubbles = []
    }
    confirmLeave = false
  }

  function send () {
    const value = text.trim()
    if (!value) return
    client.message(value)
    text = ''
  }

  function stop (e) {
    e.stopPropagation()
  }

  function onKey (e) {
    // Keep the player shortcuts (space, arrows, letters) out of the text field.
    e.stopPropagation()
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      send()
    } else if (e.key === 'Escape') {
      e.currentTarget.blur()
    }
  }

  function leave () {
    if (!confirmLeave) {
      confirmLeave = true
      later(() => { confirmLeave = false }, 3000)
      return
    }
    client.destroy()
    if (state.value === client) state.value = null
  }

  onDestroy(() => {
    detach?.()
    clearInterval(countdownTimer)
    for (const timer of timers) clearTimeout(timer)
  })
</script>

<!-- Button: hidden with the controls unless something needs attention -->
<button
  type='button'
  class='w2g-toggle btn btn-square d-flex align-items-center justify-content-center'
  class:hidden={immersed && !open && !unread}
  class:active={open}
  title='Watch Together'
  aria-label={unread ? `Watch Together, ${unread} unread message(s)` : 'Watch Together'}
  use:click={toggle}>
  <Users size='2.2rem' strokeWidth={2.5} />
  {#if unread}
    <span class='unread font-weight-bold'>{unread > 9 ? '9+' : unread}</span>
  {/if}
</button>

<!-- Prompts (host requests, invites, rejoin): above everything while the panel is closed, at its top while open -->
{#if !open && ($requests.length || $invites.length || $rejoinOffer)}
  <div class='w2g-prompts d-flex flex-column align-items-end'>
    <Prompts {client} requests={$requests} invites={$invites} rejoin={$rejoinOffer} />
  </div>
{/if}

<!-- Action notices, over the video while the panel is closed -->
{#if !open && notices.length}
  <div class='w2g-notices d-flex flex-column align-items-center'>
    {#each notices as notice (notice.id)}
      <div class='notice d-flex align-items-center rounded font-size-16 mb-5' class:interactive={notice.action} transition:fade={{ duration: 150 }}>
        <span>{notice.text}</span>
        {#if notice.action}
          <button type='button' class='btn btn-sm btn-primary ml-10' use:click={() => { notice.action.run(); dismiss(notice) }}>{notice.action.label}</button>
        {/if}
      </div>
    {/each}
  </div>
{/if}

<!-- Chat bubbles while the panel is closed -->
{#if !open && bubbles.length}
  <div class='w2g-bubbles d-flex flex-column align-items-start'>
    {#each bubbles as bubble (bubble.id)}
      <div class='bubble rounded font-size-16 mb-5 text-break-word' transition:fly={{ y: 10, duration: 150 }}>
        <span class='font-weight-bold'>{bubble.name}:</span> {bubble.message}
      </div>
    {/each}
  </div>
{/if}

<!-- Floating reactions -->
{#each floats as float (float.id)}
  <div class='w2g-float' style='right: {float.right}%'>{float.emoji}</div>
{/each}

<!-- Countdown -->
{#if $countdown && countdownLeft > 0}
  <div class='w2g-countdown d-flex align-items-center justify-content-center' transition:fade={{ duration: 150 }}>
    {#key countdownLeft}
      <div class='count font-weight-bold'>{countdownLeft}</div>
    {/key}
  </div>
{/if}

<!-- Panel -->
{#if open}
  <div class='w2g-panel bg-dark d-flex flex-column' transition:fly={{ x: 40, duration: 150 }} role='dialog' aria-label='Watch Together'>
    <div class='d-flex align-items-center px-15 pt-10 pb-5 flex-shrink-0'>
      <Users size='2rem' strokeWidth={2.5} />
      <div class='font-size-18 font-weight-bold ml-10 text-truncate'>Watch Together</div>
      <span class='mode-chip font-size-12 ml-10 text-nowrap' class:host={hostMode}>{hostMode ? 'Host controls' : 'Everyone controls'}</span>
      <button type='button' class='btn btn-square btn-sm ml-auto d-flex align-items-center justify-content-center border-0 shadow-none' title='Close' use:click={toggle}>
        <X size='1.8rem' strokeWidth={2.5} />
      </button>
    </div>

    {#if $requests.length || $invites.length || $rejoinOffer || notices.length}
      <div class='panel-prompts px-15 pt-5 flex-shrink-0'>
        <Prompts {client} requests={$requests} invites={$invites} rejoin={$rejoinOffer} {notices} dismissNotice={dismiss} />
      </div>
    {/if}

    <div class='panel-scroll d-flex flex-column flex-grow-1'>
      <div class='members px-15'>
        {#each members as member (member.userId)}
          <User compact {member} canManage={isHost} onKick={(id) => client.kick(id)} onTransfer={(id) => client.transferHost(id)} onInvite={(id) => client.invite(id)} />
        {/each}
      </div>

      <div class='d-flex flex-wrap align-items-center px-15 py-5 tools'>
        <div class='custom-switch mr-10 my-5' title='Play, pause and seek without following the lobby, and without moving the others'>
          <input type='checkbox' id='w2g-player-own' checked={!$following} on:change={({ target }) => client.setFollowing(!target.checked)} />
          <label for='w2g-player-own' class='font-size-14'>Watch on my own</label>
        </div>
        {#if isHost}
          <div class='custom-switch mr-10 my-5' title='Only the host controls playback'>
            <input type='checkbox' id='w2g-player-host-mode' checked={$lobby.mode === 'host'} on:change={({ target }) => client.setMode(target.checked ? 'host' : 'everyone')} />
            <label for='w2g-player-host-mode' class='font-size-14'>Host only</label>
          </div>
        {/if}
        {#if locked}
          <button type='button' class='btn btn-sm d-flex align-items-center mr-5 my-5' use:click={() => client.request(hostPaused ? 'play' : 'pause')}>
            <Hand size='1.4rem' class='mr-5' /> {hostPaused ? 'Request play' : 'Request pause'}
          </button>
        {/if}
        {#if canCountdown && watching}
          <button type='button' class='btn btn-sm d-flex align-items-center mr-5 my-5' title='Everyone jumps here, then plays after 3 s' use:click={() => client.startTogether()}>
            <Timer size='1.4rem' class='mr-5' /> Start together
          </button>
        {/if}
        {#if isHost && watching && $following}
          <button type='button' class='btn btn-sm d-flex align-items-center mr-5 my-5' title='Silently bring everyone to your position' use:click={() => client.resyncEveryone()}>
            <Crown size='1.4rem' class='mr-5' /> Resync everyone
          </button>
        {:else if !isHost && watching && $following}
          <button type='button' class='btn btn-sm d-flex align-items-center mr-5 my-5' title='Jump to the host' use:click={() => client.resync()}>
            <RefreshCw size='1.4rem' class='mr-5' /> Resync
          </button>
        {/if}
      </div>

      <div class='d-flex flex-wrap justify-content-between px-10 reactions'>
        {#each REACTIONS as emoji (emoji)}
          <button type='button' class='btn btn-sm reaction border-0 shadow-none' title='React {emoji}' aria-label='React {emoji}' use:click={() => client.react(emoji)}>{emoji}</button>
        {/each}
      </div>

      <div class='chat flex-grow-1 px-15 py-5' bind:this={chatBox}>
        {#each chat as entry (entry)}
          {#if entry.type === 'system'}
            <div class='line system text-muted font-size-12 text-break-word'>{entry.message}</div>
          {:else}
            <div class='line font-size-14 text-break-word pre-wrap' class:own={entry.type === 'outgoing'}>
              <span class='font-weight-bold'>{entry.type === 'outgoing' ? 'You' : memberName(entry.user)}</span> {entry.message}
            </div>
          {/if}
        {:else}
          <div class='text-muted font-size-12 py-10 text-center'>No messages yet</div>
        {/each}
      </div>
    </div>

    <div class='d-flex align-items-center px-10 py-10 flex-shrink-0 composer'>
      <button type='button' class='btn btn-sm d-flex align-items-center justify-content-center text-danger border-0 shadow-none leave' class:confirm={confirmLeave} title='Leave the lobby' use:click={leave}>
        {#if confirmLeave}<span class='font-size-12 px-5'>Leave?</span>{:else}<DoorOpen size='1.8rem' strokeWidth={2.5} />{/if}
      </button>
      <input
        type='text'
        class='form-control flex-grow-1 mx-10'
        maxlength='2048'
        autocomplete='off'
        enterkeyhint='send'
        placeholder='Message'
        bind:value={text}
        on:keydown={onKey}
        on:keyup={stop}
        on:keypress={stop} />
      <button type='button' class='btn btn-sm btn-square d-flex align-items-center justify-content-center border-0 shadow-none' title='Send' use:click={send}>
        <SendHorizontal size='1.8rem' strokeWidth={2.5} />
      </button>
    </div>
  </div>
{/if}

<style>
  .w2g-toggle {
    --w2g-top: max(1.5rem, var(--safe-area-top, 0px), env(safe-area-inset-top, 0px));
    --w2g-right: max(2rem, var(--safe-area-right, 0px), env(safe-area-inset-right, 0px));
    position: absolute;
    top: var(--w2g-top);
    right: var(--w2g-right);
    z-index: 45;
    width: 4.4rem;
    height: 4.4rem;
    border-radius: 50%;
    border: 0;
    color: hsl(var(--white-color-hsl));
    background: hsla(var(--black-color-hsl), 0.45);
    backdrop-filter: blur(6px);
    transition: opacity 0.2s ease;
    pointer-events: all;
  }
  .w2g-toggle.active {
    background: hsla(var(--white-color-hsl), 0.25);
  }
  .w2g-toggle.hidden {
    opacity: 0;
    pointer-events: none;
  }
  .unread {
    position: absolute;
    top: -0.4rem;
    right: -0.4rem;
    min-width: 2rem;
    height: 2rem;
    padding: 0 0.5rem;
    border-radius: 1rem;
    font-size: 1.2rem;
    line-height: 2rem;
    text-align: center;
    background: var(--error-color-very-light);
    color: hsl(var(--white-color-hsl));
  }

  /* Above the panel (55) and the controls: prompts must always be visible and clickable. */
  .w2g-prompts {
    position: absolute;
    top: calc(max(1.5rem, var(--safe-area-top, 0px), env(safe-area-inset-top, 0px)) + 5.5rem);
    right: max(2rem, var(--safe-area-right, 0px), env(safe-area-inset-right, 0px));
    z-index: 60;
    width: 30rem;
    max-width: calc(100% - 4rem);
    max-height: calc(100% - 8rem);
    overflow-y: auto;
  }
  .panel-prompts {
    max-height: 40%;
    overflow-y: auto;
    border-bottom: 1px solid hsla(var(--white-color-hsl), 0.08);
  }

  .w2g-notices {
    position: absolute;
    top: calc(max(1.5rem, var(--safe-area-top, 0px), env(safe-area-inset-top, 0px)) + 6rem);
    left: 50%;
    transform: translateX(-50%);
    z-index: 60;
    max-width: calc(100% - 4rem);
    pointer-events: none;
  }
  .notice {
    padding: 0.7rem 1.4rem;
    color: #fff;
    background: hsla(var(--black-color-hsl), 0.7);
    backdrop-filter: blur(6px);
    text-align: center;
  }
  .notice.interactive {
    pointer-events: all;
  }

  .w2g-bubbles {
    position: absolute;
    left: max(2rem, var(--safe-area-left, 0px), env(safe-area-inset-left, 0px));
    bottom: max(11rem, calc(env(safe-area-inset-bottom, 0px) + 9rem));
    z-index: 44;
    max-width: min(45rem, calc(100% - 4rem));
    pointer-events: none;
  }
  .bubble {
    padding: 0.6rem 1.2rem;
    color: #fff;
    background: hsla(var(--black-color-hsl), 0.65);
    backdrop-filter: blur(6px);
  }

  .w2g-float {
    position: absolute;
    bottom: 12rem;
    z-index: 44;
    font-size: 4rem;
    pointer-events: none;
    animation: float-up 2.6s ease-out forwards;
  }
  @keyframes float-up {
    0% { transform: translateY(0) scale(0.6); opacity: 0; }
    15% { transform: translateY(-2rem) scale(1.1); opacity: 1; }
    100% { transform: translateY(-22rem) scale(1); opacity: 0; }
  }

  .w2g-countdown {
    position: absolute;
    inset: 0;
    z-index: 47;
    pointer-events: none;
    background: hsla(var(--black-color-hsl), 0.35);
  }
  .count {
    font-size: 14rem;
    line-height: 1;
    filter: drop-shadow(0 0 1.5rem hsla(var(--black-color-hsl), 0.8));
    animation: pop 1s ease-out;
  }
  @keyframes pop {
    from { transform: scale(1.4); opacity: 0.4; }
    to { transform: scale(1); opacity: 1; }
  }

  .w2g-panel {
    position: absolute;
    top: max(1rem, var(--safe-area-top, 0px), env(safe-area-inset-top, 0px));
    bottom: max(1rem, var(--safe-area-bottom, 0px), env(safe-area-inset-bottom, 0px));
    right: max(1rem, var(--safe-area-right, 0px), env(safe-area-inset-right, 0px));
    width: 38rem;
    max-width: calc(100% - 2rem);
    z-index: 55;
    border-radius: 1.2rem;
    box-shadow: var(--dm-shadow);
    cursor: auto;
    overflow: hidden;
    user-select: text;
  }
  .panel-scroll {
    min-height: 0;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
  .members {
    flex-shrink: 0;
  }
  .tools {
    flex-shrink: 0;
    border-top: 1px solid hsla(var(--white-color-hsl), 0.08);
  }
  .reactions {
    flex-shrink: 0;
  }
  .reaction {
    font-size: 2.2rem;
    line-height: 1;
    min-width: 4.2rem;
    height: 4.2rem;
    padding: 0;
    background: transparent;
  }
  .chat {
    min-height: 14rem;
    overflow-y: auto;
    border-top: 1px solid hsla(var(--white-color-hsl), 0.08);
  }
  .line {
    padding: 0.3rem 0;
  }
  .line.system {
    font-style: italic;
  }
  .line.own {
    color: hsla(var(--white-color-hsl), 0.85);
  }
  .composer {
    border-top: 1px solid hsla(var(--white-color-hsl), 0.08);
    padding-bottom: max(1rem, env(safe-area-inset-bottom, 0px));
  }
  .composer .form-control {
    min-width: 0;
  }
  .leave {
    min-width: 3.6rem;
    height: 3.6rem;
  }
  .leave.confirm {
    background: var(--error-color-light);
    color: hsl(var(--white-color-hsl)) !important;
  }
  .mode-chip {
    padding: 0.1rem 0.8rem;
    border-radius: 1rem;
    background: hsla(var(--white-color-hsl), 0.1);
  }
  .mode-chip.host {
    background: hsla(45, 90%, 60%, 0.18);
    color: #F5C542;
  }

  /* Phones: the panel takes the whole player; buttons stay big enough for a thumb. */
  @media (max-width: 600px) {
    .w2g-panel {
      left: max(0.5rem, var(--safe-area-left, 0px), env(safe-area-inset-left, 0px));
      right: max(0.5rem, var(--safe-area-right, 0px), env(safe-area-inset-right, 0px));
      width: auto;
      max-width: none;
    }
  }
  @media (pointer: coarse) {
    .w2g-toggle {
      width: 5rem;
      height: 5rem;
    }
    .reaction {
      min-width: 4.8rem;
      height: 4.8rem;
    }
  }
</style>
