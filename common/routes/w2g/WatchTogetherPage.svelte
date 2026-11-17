<script context='module'>
  import { copyToClipboard } from '@/modules/clipboard.js'
  import { status } from '@/modules/networking.js'
  import { SUPPORTS } from '@/modules/support.js'
  import { page } from '@/modules/navigation.js'
  import { IPC } from '@/modules/bridge.js'
  import { anilistClient } from '@/modules/anilist.js'
  import { settings } from '@/modules/settings.js'
  import { toast } from 'svelte-sonner'
  import {
    w2gEmitter as sessionEmitter,
    state as sessionState
  } from '@/routes/w2g/components/session.js'
  import { installPushToTalk } from '@/routes/w2g/components/voice.js'
  import { parseLobbyCode } from '@/routes/w2g/components/sync.js'
  import 'browser-event-target-emitter'
  import Debug from 'debug'
  const debug = Debug('ui:w2g')

  // Re-exported for existing imports (PlayerPage); the state lives in session.js.
  export const w2gEmitter = sessionEmitter
  export const state = sessionState

  function joinLobby (code) {
    debug('Joining lobby with code:', code)
    if (state.value) state.value.destroy()
    const w2g = new W2GClient(code, { displayName: settings.value.w2gDisplayName })
    state.value = w2g
    // Prompts of this lobby (invites, Join): gone when we leave it, their Join would do nothing.
    const toastIds = new Set()
    w2g.on('destroyed', () => {
      for (const id of toastIds) toast.dismiss(id)
      toastIds.clear()
    })
    w2g.on('index', (i) => w2gEmitter.emit('setindex', i))
    // { time, paused, action, by, rate }: applied silently when action is 'sync'.
    w2g.on('player', (playerState) => w2gEmitter.emit('playerupdate', playerState))
    // The host accepted a request: the player does it as a local action.
    w2g.on('perform', (request) => w2gEmitter.emit('perform', request))
    w2g.on('kicked', () => {
      if (state.value !== w2g) return
      w2g.destroy()
      state.value = null
      toast.error('Watch Together', { description: 'You were removed from the lobby' })
    })
    // Someone started a title: start the same one here with our own extension.
    w2g.on('media', ({ media, episode }) => {
      const number = typeof episode === 'object' ? episode?.number : episode
      toast('Watch Together', {
        description: `Starting ${anilistClient.title(media) || 'the shared title'}${number ? ` - Episode ${number}` : ''}`
      })
      window.dispatchEvent(
        new CustomEvent('w2g-play', { detail: { media, episode } })
      )
    })
    // Invite to watch: the player shows its own prompt; elsewhere, an app-wide toast with Join.
    const inviteToastId = (from) => `w2g-invite-${from}`
    w2g.on('invite', (invitation) => {
      if (page.value === page.PLAYER) return
      const label = [anilistClient.title(invitation.media) || 'a title', w2g.episodeLabel(invitation.episode)].filter(Boolean).join(' · ')
      // Same id: a new invite from the same sender replaces the previous toast.
      const id = inviteToastId(invitation.from)
      toastIds.add(id)
      toast('Watch Together', {
        id,
        description: `${invitation.name} invites you to watch ${label}`,
        duration: Infinity,
        action: { label: 'Join', onClick: () => w2g.joinInvite(invitation.from) },
        onDismiss: () => w2g.dismissInvite(invitation.from)
      })
    })
    w2g.on('inviteRemoved', (from) => {
      toastIds.delete(inviteToastId(from))
      toast.dismiss(inviteToastId(from))
    })
    // v2.3: we arrived in a lobby that is already watching: one app-wide prompt, wherever we are.
    const joinToastId = `w2g-join-${w2g.code}`
    w2g.on('joinable', (offer) => {
      const label = [anilistClient.title(offer.media) || 'a title', w2g.episodeLabel(offer.episode)].filter(Boolean).join(' · ')
      toastIds.add(joinToastId)
      toast('Watch Together', {
        id: joinToastId,
        description: `${offer.name} is watching ${label}`,
        duration: Infinity,
        action: { label: 'Join', onClick: () => w2g.joinPlayback() }
      })
    })
    w2g.on('joinableRemoved', () => toast.dismiss(joinToastId))

    if (!code) invite()
  }

  w2gEmitter.on('player', (data) => state.value?.playerStateChanged(data))
  w2gEmitter.on('index', (index) => state.value?.mediaIndexChanged(index))
  // v2.4: push-to-talk key, anywhere in the app while in voice.
  installPushToTalk(() => state.value)

  IPC.on('w2glink', (link) => {
    // tsumi://w2g/CODE (maybe with a trailing slash or a query) and Discord join secrets: the code only.
    const code = parseLobbyCode(link)
    if (!code) {
      // tsumi://w2g/ without a code: the jump-list task "Create a New Watch Together Lobby". It creates one, or shows
      // the lobby we are in (a new lobby would leave it). Any other text without a code is ignored.
      if (typeof link !== 'string' || !/^[\s/]*$/.test(link)) return
      page.navigateTo(page.WATCH_TOGETHER)
      if (!state.value) joinLobby()
      return
    }
    page.navigateTo(page.WATCH_TOGETHER)
    // Our own lobby: just show it (joining again would leave it, and the host would lose its role).
    if (state.value?.code === code) return
    joinLobby(code)
  })

  function invite () {
    copyToClipboard(state.value.inviteLink, 'invite code')
  }
</script>

<script>
  import Lobby from '@/routes/w2g/components/Lobby.svelte'
  import { Plus, UserPlus } from 'lucide-svelte'
  import { W2GClient } from '@/routes/w2g/components/w2g.js'
  import { click } from '@/modules/click.js'

  let joinText

  function checkInvite (invite) {
    if (!invite) return
    // The 16 hex characters of a code or link, in lower case (sync.js parseLobbyCode).
    const match = parseLobbyCode(invite)
    if (!match) return
    page.navigateTo(page.WATCH_TOGETHER)
    if (state.value?.code !== match) joinLobby(match)
    joinText = ''
  }

  $: checkInvite(joinText)
</script>

<div
  class='d-flex h-full align-items-center flex-column px-md-20 overflow-y-auto scroll-container pl-sm-30 pl-md-80'
  class:pt-safe-area={!$status.match(/offline/i)}
>
  {#if !$state}
    <div class='font-scale-50 font-weight-bold pt-20 mt-20 root'>
      Watch Together
    </div>
    <div
      class='d-flex flex-row flex-wrap justify-content-center align-items-center h-auto mb-20 pb-20 root position-relative w-full'
      class:h-full={!SUPPORTS.isAndroid}
    >
      <div
        class='card d-flex flex-column align-items-center w-300 h-300 justify-content-end'
      >
        <UserPlus size='6rem' class='d-flex align-items-center h-full' />
        <h2 class='font-weight-bold font-scale-34'>Join Lobby</h2>
        <input
          type='text'
          class='form-control h-80 text-center'
          autocomplete='off'
          bind:value={joinText}
          data-option='search'
          placeholder='Lobby Code or Link'
        />
      </div>
      <div
        class='card d-flex flex-column align-items-center w-300 h-300 justify-content-end'
      >
        <Plus size='6rem' class='d-flex align-items-center h-full' />
        <button
          class='btn btn-primary btn-lg mt-10 btn-block d-flex align-items-center justify-content-center'
          type='button'
          use:click={() => joinLobby()}><span>Create Lobby</span></button
        >
      </div>
    </div>
  {:else}
    <Lobby {state} {invite} />
  {/if}
</div>
