<script>
  import SettingCard from '@/routes/settings/components/SettingCard.svelte'
  import { click } from '@/modules/click.js'
  import { Trash2 } from 'lucide-svelte'
  import { SPOILER_LEVELS, SPOILER_STATUSES, SPOILER_DESCRIPTION, SPOILER_STATUS_DESCRIPTION } from '@/modules/spoilers.js'

  // Spoiler protection (common/modules/spoilers.js), in Settings > Interface.
  export let settings

  $: if (!Array.isArray(settings.spoilerStatus)) settings.spoilerStatus = []
  $: unusedStatuses = SPOILER_STATUSES.filter(([, value]) => !settings.spoilerStatus?.includes(value))
</script>

<SettingCard title='Spoiler Protection' description={SPOILER_DESCRIPTION}>
  <select class='form-control bg-dark w-150 mw-full text-truncate' bind:value={settings.spoilers}>
    {#each SPOILER_LEVELS as [label, value] (value)}
      <option {value}>{label}</option>
    {/each}
  </select>
</SettingCard>
{#if settings.spoilers && settings.spoilers !== 'off'}
  <SettingCard title='Spoiler Protection Statuses' description={SPOILER_STATUS_DESCRIPTION}>
    <div>
      {#each settings.spoilerStatus as status, i (i)}
        <div class='input-group mb-10 w-210 mw-full'>
          <select id='spoiler-status-{i}' class='w-100 form-control mw-full bg-dark text-truncate' bind:value={settings.spoilerStatus[i]}>
            <option disabled value=''>Select a status</option>
            {#each SPOILER_STATUSES.filter(([, value]) => !settings.spoilerStatus.includes(value) || status === value) as [label, value] (value)}
              <option {value}>{label}</option>
            {/each}
          </select>
          <div class='input-group-append'>
            <button type='button' title='Remove' use:click={() => { settings.spoilerStatus.splice(i, 1); settings.spoilerStatus = settings.spoilerStatus }} class='btn btn-danger btn-square input-group-append px-5 d-flex align-items-center'><Trash2 size='1.8rem' /></button>
          </div>
        </div>
      {/each}
      <button type='button' disabled={!unusedStatuses.length} use:click={() => { if (unusedStatuses.length) settings.spoilerStatus = [...settings.spoilerStatus, unusedStatuses[0][1]] }} class='btn btn-primary mb-10 mr-10 d-flex align-items-center justify-content-center'><span>Add Status</span></button>
    </div>
  </SettingCard>
{/if}

<style>
  .w-210 {
    width: 21rem;
  }
</style>
