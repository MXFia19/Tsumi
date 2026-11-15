<script>
  import SettingCard from '@/routes/settings/components/SettingCard.svelte'
  import { downloadsSupported, downloadInfo, chooseDownloadFolder, openDownloadFolder } from '@/modules/downloads/downloads.js'
  import { click } from '@/modules/click.js'
  import { Eraser, FolderOpen } from 'lucide-svelte'

  // Settings > App > Download Settings (offline downloads, common/modules/downloads/downloads.js).
  export let settings

  async function pickFolder () {
    const folder = await chooseDownloadFolder()
    if (folder) settings.downloadFolder = folder
  }
</script>

{#if downloadsSupported}
  <h4 class='mb-10 font-weight-bold'>Download Settings</h4>
  <SettingCard title='Download Folder' description='Where downloaded episodes are saved, one folder per title. Downloads already saved stay where they are.'>
    <div class='input-group mw-100 w-400 mw-full'>
      <div class='input-group-prepend'>
        <button type='button' use:click={pickFolder} class='btn btn-primary input-group-append d-flex align-items-center justify-content-center'><span>Select Folder</span></button>
      </div>
      <input type='text' class='form-control bg-dark text-truncate mw-100' readonly value={settings.downloadFolder || $downloadInfo.defaultFolder} placeholder='Videos/Tsumi' />
      <div class='input-group-prepend'>
        <button type='button' use:click={() => openDownloadFolder()} class='btn btn-square bg-dark-light input-group-append px-5 d-flex align-items-center' title='Open Folder'><FolderOpen size='1.8rem' /></button>
        <button type='button' use:click={() => { settings.downloadFolder = '' }} disabled={!settings.downloadFolder} class='btn btn-danger btn-square input-group-append px-5 d-flex align-items-center' title='Reset to Default'><Eraser size='1.8rem' /></button>
      </div>
    </div>
  </SettingCard>
  <SettingCard title='Simultaneous Downloads' description='How many episodes download at the same time. The others wait in the queue.'>
    <select class='form-control bg-dark w-150 mw-full' bind:value={settings.downloadMaxConcurrent}>
      <option value={1}>1</option>
      <option value={2}>2</option>
      <option value={3}>3</option>
      <option value={4}>4</option>
      <option value={5}>5</option>
    </select>
  </SettingCard>
  <SettingCard title='Download Quality' description='Quality picked when the source offers several (HLS streams). Sources with a single quality are downloaded as they are.'>
    <select class='form-control bg-dark w-150 mw-full' bind:value={settings.downloadQuality}>
      <option value='highest'>Highest</option>
      <option value='1080'>1080p</option>
      <option value='720'>720p</option>
      <option value='480'>480p</option>
      <option value='360'>360p</option>
      <option value='lowest'>Lowest</option>
    </select>
  </SettingCard>
{/if}
