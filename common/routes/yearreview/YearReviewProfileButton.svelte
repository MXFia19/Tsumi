<script>
  // "Year in Review" button of the Profiles modal (current profile). MyAnimeList profiles get the explanation screen.
  import { openYearReview } from '@/modules/yearreview/yearreview.js'
  import { click } from '@/modules/click.js'
  import { Sparkles } from 'lucide-svelte'
</script>

<button type='button' class='yr-button pointer border-0 rounded mb-15 pt-10 pb-10 d-flex align-items-center justify-content-center text-center w-full' use:click={() => openYearReview()}>
  <Sparkles class='mr-10' size='2rem' />
  <div class='mt-2 font-weight-bold'>Year in Review</div>
</button>

<style>
  .yr-button {
    background: color-mix(in srgb, var(--accent-color) 14%, var(--dark-color-light));
    border-radius: 3rem !important;
  }
  @media (hover: hover) and (pointer: fine) {
    .yr-button:hover {
      background: color-mix(in srgb, var(--accent-color) 24%, var(--dark-color-light));
    }
  }
</style>
