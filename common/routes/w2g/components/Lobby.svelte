<script>
  import { readable } from 'svelte/store'
  import { click } from '@/modules/click.js'
  import { settings } from '@/modules/settings.js'
  import Helper from '@/modules/helper.js'
  import User from '@/routes/w2g/components/User.svelte'
  import Message from '@/routes/w2g/components/Message.svelte'
  import { anilistClient } from '@/modules/anilist.js'
  import { SendHorizontal, DoorOpen, UserPlus, Crown, Users, RefreshCw, MonitorPlay } from 'lucide-svelte'
  export let invite

  /** @type {import('simple-store-svelte').Writable<import('./w2g.js').W2GClient | null>} */
  export let state

  // Sync badges age with time (No signal, drift of a playing member).
  const clock = readable(Date.now(), set => {
    const interval = setInterval(() => set(Date.now()), 1000)
    return () => clearInterval(interval)
  })

  const loggedIn = !!Helper.getUser()
  let displayName = $settings.w2gDisplayName || ''

  function cleanup () {
    state.value?.destroy()
    state.value = null
  }

  $: client = $state
  $: peers = client?.peers
  $: messages = client?.messages
  $: lobby = client?.lobby
  $: signals = client?.signals
  $: localStatus = client?.localStatus
  $: following = client?.following
  $: rejoinOffer = client?.rejoinOffer

  // The stores are passed so the list is rebuilt whenever one of them changes.
  function listMembers (client, now, ..._stores) {
    return client?.describeMembers(now) ?? []
  }
  $: members = listMembers(client, $clock, $peers, $lobby, $signals, $localStatus)
  $: isHost = !!client && $lobby?.hostId != null && String($lobby.hostId) === client.selfId
  $: hostMode = $lobby?.hostId != null && $lobby?.mode === 'host'
  $: watching = !!$localStatus && $localStatus.state !== 'idle'
  $: rejoinLabel = $rejoinOffer ? [anilistClient.title($rejoinOffer.media) || 'the lobby title', client.episodeLabel($rejoinOffer.episode)].filter(Boolean).join(' · ') : ''

  function saveDisplayName () {
    const value = displayName.trim().slice(0, 32)
    displayName = value
    $settings.w2gDisplayName = value
    client?.setDisplayName(value)
  }

  /**
   * @param {import('./w2g.js').ChatEntry[]} messages
   */
  function groupMessages (messages) {
    if (!messages?.length) return []
    const grouped = []
    for (const { message, user, type, date } of messages.slice(-50)) {
      const last = grouped[grouped.length - 1]
      if (type !== 'system' && last && last.type !== 'system' && String(last.user?.id) === String(user?.id)) {
        last.messages.push(message)
      } else {
        grouped.push({ user, messages: [message], type, date })
      }
    }
    return grouped
  }

  let message = ''
  let rows = 1

  function sendMessage () {
    if (message.trim()) {
      state.value.message(message.trim())
      message = ''
      rows = 1
    }
  }

  function checkInput (e) {
    if (e.key === 'Enter' && e.shiftKey === false && message.trim()) {
      sendMessage()
      e.preventDefault()
    } else {
      rows = message.split('\n').length || 1
    }
  }
</script>

<div class='d-flex flex-column root w-full position-relative px-md-20 h-full overflow-hidden'>
  <div class='d-flex flex-md-row flex-column-reverse w-full h-full pt-20 scroll-container pb-transition'>
    <div class='d-flex flex-column justify-content-end overflow-hidden flex-grow-1 px-20 pb-md-20'>
      {#each groupMessages($messages) as { user, messages, type, date } (date)}
        {#if type === 'system'}
          <div class='system-line text-muted font-size-14 text-center pre-wrap text-break-word mt-10 px-20'>
            {messages[0]}
          </div>
        {:else}
          <Message time={date} {user} {messages} {type} />
        {/if}
      {/each}
      <div class='d-flex my-10'>
        <button class='btn text-danger d-flex mt-auto align-items-center justify-content-center mr-10 border-0 px-0 shadow-none' title='Leave' type='button' use:click={cleanup} style='height: 3.75rem !important; width: 3.75rem !important;'>
          <DoorOpen size='1.8rem' strokeWidth={2.5} />
        </button>
        <button class='btn text-success d-flex mt-auto align-items-center justify-content-center mr-20 border-0 px-0 shadow-none' title='Invite' type='button' use:click={invite} style='height: 3.75rem !important; width: 3.75rem !important;'>
          <UserPlus size='1.8rem' strokeWidth={2.5} />
        </button>
        <textarea
          bind:value={message}
          class='form-control h-auto mt-20 px-15 d-flex align-items-center justify-content-center line-height-normal w-auto flex-grow-1 shadow-0 long-input'
          {rows}
          style='resize: none; min-height: 0 !important'
          autocomplete='off'
          maxlength='2048'
          placeholder='Message' on:keydown={checkInput}></textarea>
        <button class='btn d-flex mt-auto align-items-center justify-content-center ml-20 border-0 px-0 shadow-none' title='Send' type='button' use:click={sendMessage} style='height: 3.75rem !important; width: 3.75rem !important;'>
          <SendHorizontal size='1.8rem' strokeWidth={2.5} />
        </button>
      </div>
    </div>
    <div class='d-flex flex-column w-350 mw-full px-20 flex-shrink-0'>
      {#if client}
        <div class='d-flex align-items-center flex-wrap pb-10'>
          <span class='mode-chip d-flex align-items-center font-size-14 mr-10 mb-5' class:host={hostMode} title={hostMode ? 'Only the host can play, pause and seek' : 'Anyone can play, pause and seek'}>
            {#if hostMode}<Crown size='1.4rem' class='mr-5' />{:else}<Users size='1.4rem' class='mr-5' />{/if}
            {hostMode ? 'Host controls playback' : 'Everyone controls playback'}
          </span>
          {#if isHost}
            <div class='custom-switch mb-5 mr-10' title='Only the host controls playback'>
              <input type='checkbox' id='w2g-host-mode' checked={$lobby?.mode === 'host'} on:change={({ target }) => client.setMode(target.checked ? 'host' : 'everyone')} />
              <label for='w2g-host-mode' class='font-size-14'>Host only</label>
            </div>
          {:else if watching && $following}
            <button type='button' class='btn btn-sm d-flex align-items-center mb-5' title='Jump to the host' use:click={() => client.resync()}>
              <RefreshCw size='1.4rem' class='mr-5' /> Resync
            </button>
          {/if}
        </div>
        <div class='d-flex align-items-center flex-wrap pb-10'>
          <div class='custom-switch mb-5 mr-10' title='Play, pause and seek without following the lobby, and without moving the others'>
            <input type='checkbox' id='w2g-own' checked={!$following} on:change={({ target }) => client.setFollowing(!target.checked)} />
            <label for='w2g-own' class='font-size-14'>Watch on my own</label>
          </div>
          {#if $rejoinOffer}
            <button type='button' class='btn btn-sm btn-primary d-flex align-items-center mb-5 mw-full' title='Start the lobby episode, then sync' use:click={() => client.rejoin()}>
              <MonitorPlay size='1.4rem' class='mr-5 flex-shrink-0' /><span class='text-truncate'>Rejoin {rejoinLabel}</span>
            </button>
          {/if}
        </div>
        {#if !loggedIn}
          <div class='pb-10'>
            <label for='w2g-display-name' class='font-size-14 text-muted mb-5'>Your name in the lobby</label>
            <input
              id='w2g-display-name'
              type='text'
              class='form-control'
              maxlength='32'
              autocomplete='off'
              placeholder='Display name'
              bind:value={displayName}
              on:change={saveDisplayName}
              on:keydown={(e) => e.key === 'Enter' && e.currentTarget.blur()} />
          </div>
        {/if}
        <div class='font-size-20 font-weight-bold pl-5 pb-10'>
          {members.length} Member(s)
        </div>
        {#each members as member (member.userId)}
          <User {member} canManage={isHost} onKick={(id) => client.kick(id)} onTransfer={(id) => client.transferHost(id)} onInvite={(id) => client.invite(id)} />
        {/each}
      {/if}
    </div>
  </div>
</div>

<style>
  .pb-transition {
    transition: padding .4s ease;
    will-change: padding;
  }
  .mode-chip {
    padding: 0.3rem 0.9rem;
    border-radius: 1.5rem;
    background: hsla(var(--white-color-hsl), 0.1);
  }
  .mode-chip.host {
    background: hsla(45, 90%, 60%, 0.18);
    color: #F5C542;
  }
  .system-line {
    font-style: italic;
  }
</style>
