<script>
  import { click } from '@/modules/click.js'
  import { settings } from '@/modules/settings.js'
  import { keyLabel } from '@/routes/w2g/components/voice.js'
  import { Headphones, HeadphoneOff, Mic, MicOff } from 'lucide-svelte'

  /**
   * v2.4 voice controls (lobby page and player panel): Join voice / Leave voice, Mute / Unmute, push-to-talk hint.
   */

  /** @type {import('./w2g.js').W2GClient} */
  export let client

  /** Smaller buttons, for the player panel. */
  export let compact = false

  $: voice = client.voice
  $: pushToTalk = $settings.w2gPushToTalk === true
  $: key = keyLabel($settings.w2gPushToTalkKey)
</script>

<div class='d-flex align-items-center flex-wrap voice-controls' class:compact>
  {#if $voice.joined}
    <button type='button' class='btn btn-sm d-flex align-items-center mr-5 my-5 text-danger' title='Stop listening and talking' use:click={() => client.leaveVoice()}>
      <HeadphoneOff size='1.4rem' class='mr-5' /> Leave voice
    </button>
    {#if $voice.hasMic}
      {#if pushToTalk}
        <span class='ptt font-size-12 mr-5 my-5 d-flex align-items-center' class:live={$voice.transmitting} title='Set the key in Settings > Player'>
          <Mic size='1.3rem' class='mr-5' /> {$voice.transmitting ? 'Talking…' : `Hold ${key} to talk`}
        </span>
      {:else}
        <button type='button' class='btn btn-sm d-flex align-items-center mr-5 my-5' class:muted={$voice.muted} title={$voice.muted ? 'Unmute your microphone' : 'Mute your microphone'} use:click={() => client.setVoiceMuted(!$voice.muted)}>
          {#if $voice.muted}<MicOff size='1.4rem' class='mr-5' /> Unmute{:else}<Mic size='1.4rem' class='mr-5' /> Mute{/if}
        </button>
      {/if}
    {/if}
    {#if $voice.speaking}
      <span class='speaking-dot my-5' title='You are speaking'></span>
    {/if}
  {:else}
    <button type='button' class='btn btn-sm btn-primary d-flex align-items-center mr-5 my-5' disabled={$voice.starting} title='Talk with the lobby (microphone, echo cancellation on)' use:click={() => client.joinVoice()}>
      <Headphones size='1.4rem' class='mr-5' /> {$voice.starting ? 'Joining…' : 'Join voice'}
    </button>
  {/if}
  {#if $voice.error}
    <span class='text-muted font-size-12 w-full'>{$voice.error}</span>
  {/if}
</div>

<style>
  .ptt {
    padding: 0.3rem 0.9rem;
    border-radius: 1.5rem;
    background: hsla(var(--white-color-hsl), 0.1);
  }
  .ptt.live {
    background: hsla(var(--completed-hsl), 0.25);
    color: var(--completed-color);
  }
  .muted {
    background: var(--error-color-light);
    color: hsl(var(--white-color-hsl)) !important;
  }
  .speaking-dot {
    width: 1rem;
    height: 1rem;
    border-radius: 50%;
    background: var(--completed-color);
    box-shadow: 0 0 0 0.3rem hsla(var(--completed-hsl), 0.3);
  }
</style>
