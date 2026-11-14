<script>
  import { memberName } from '@/routes/w2g/components/sync.js'

  /** @type {any} */
  export let user = {}

  /** @type {string[]} */
  export let messages = []

  /** @type {Date} */
  export let time

  /** @type {'incoming' | 'outgoing'} */
  export let type = 'incoming'
  $: incoming = type === 'incoming'
</script>

<div class='message d-flex flex-row mt-15 overflow-y-auto' class:flex-row={incoming} class:flex-row-reverse={!incoming}>
  <img src={user?.avatar?.medium || user?.picture || 'https://s4.anilist.co/file/anilistcdn/user/avatar/large/default.png'} alt='ProfilePicture' class='w-50 h-50 rounded-circle p-5 mt-auto' />
  <div class='d-flex flex-column px-10 align-items-start flex-auto' class:align-items-start={incoming} class:align-items-end={!incoming}>
    <div class='pb-5 d-flex flex-row align-items-center px-5'>
      <div class='font-weight-bold font-size-18 line-height-normal'>
        {memberName(user)}
      </div>
      <div class='text-muted pl-10 font-size-12 line-height-normal'>
        {time.toLocaleTimeString()}
      </div>
    </div>
    {#each messages as message, i (i)}
      <div class='py-10 px-15 rounded-top mb-5 select-all pre-wrap text-break-word' style='max-width: calc(100% - 10rem)'
        class:bg-dark-light={incoming} class:own={!incoming}
        class:rounded-right={incoming} class:rounded-left={!incoming}>
        {message}
      </div>
    {/each}
  </div>
</div>

<style>
  .message {
    --base-border-radius: 1.3rem;
  }
  /* Own messages: tinted with the accent but dark enough for white text in any theme. A light accent
     (white by default) used as is gave light text on white. Any accent mixed at 30% into the dark base
     stays under ~10% luminance, so white text keeps a contrast of at least 7:1. */
  .own {
    background-color: hsla(var(--white-color-hsl), 0.2);
    background-color: color-mix(in srgb, var(--accent-color) 30%, hsl(var(--dark-color-light-hsl)));
    color: #fff;
  }
  .flex-auto {
    flex: auto;
  }
</style>
