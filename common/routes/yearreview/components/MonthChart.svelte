<script>
  import { MONTHS, formatNumber } from '@/modules/yearreview/stats.js'

  /** @type {number[]} episodes per month (12 values) */
  export let months = []

  $: max = Math.max(1, ...months)
  $: best = months.indexOf(Math.max(...months))
</script>

<div class='chart d-flex w-full' role='img' aria-label='Episodes watched per month'>
  {#each months as value, index (index)}
    {@const height = value ? Math.max(3, (value / max) * 100) : 1}
    <div class='column d-flex flex-column align-items-center h-full' title='{MONTHS[index]}: {formatNumber(value)} episode{value === 1 ? '' : 's'}'>
      <div class='track w-full position-relative'>
        <div class='bar w-full position-absolute' class:best={index === best && value > 0} style='height: {height}%'></div>
        {#if value}
          <div class='value w-full text-center position-absolute font-size-12 font-weight-bold' style='bottom: calc({height}% + 0.4rem)'>{formatNumber(value)}</div>
        {/if}
      </div>
      <div class='label font-size-12 text-muted mt-5'>{MONTHS[index]}</div>
    </div>
  {/each}
</div>

<style>
  .chart {
    height: 22rem;
    gap: 0.8rem;
    padding-top: 2rem;
  }
  .column {
    flex: 1 1 0;
    min-width: 0;
  }
  .track {
    flex: 1 1 auto;
    min-height: 0;
  }
  .bar {
    bottom: 0;
    left: 0;
    border-radius: 0.6rem 0.6rem 0.2rem 0.2rem;
    background: var(--accent-color);
    opacity: 0.35;
    transition: opacity 0.2s ease;
  }
  .bar.best {
    opacity: 1;
  }
  .column:hover .bar {
    opacity: 0.8;
  }
  .value {
    left: 0;
    color: rgba(255, 255, 255, 0.75);
  }
  .label {
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
</style>
