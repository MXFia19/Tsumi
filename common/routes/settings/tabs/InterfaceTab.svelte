<script>
  import { variables, setScale } from '@/modules/themes.js'
  import { click } from '@/modules/click.js'
  import HomeSections from '@/routes/settings/components/HomeSections.svelte'
  import SpoilerSettings from '@/routes/settings/components/SpoilerSettings.svelte'
  import MovieAlertsSettings from '@/routes/settings/components/MovieAlertsSettings.svelte'
  import { IPC } from '@/modules/bridge.js'
  import SettingCard from '@/routes/settings/components/SettingCard.svelte'
  import { SUPPORTS } from '@/modules/support.js'
  import { Trash2, RotateCcw } from 'lucide-svelte'
  import { genreList, tagList } from '@/modules/anime/anime.js'
  import { tmdbGenreList } from '@/modules/tmdb.js'
  import CustomDropdown from '@/components/CustomDropdown.svelte'
  import Helper from '@/modules/helper.js'
  import { onDestroy } from 'svelte'
  import { sections } from '@/modules/sections.js'
  import { uniqueSectionTitle, renameHomeSection, removeHomeSection } from '@/modules/homesections.js'
  function updateAngle () {
    IPC.emit('set:angle', settings.angle)
  }
  export let settings

  // Custom sections (Anime / Western): Home lists them by title (settings.homeSections), so a rename follows there, a
  // deleted section leaves it, and titles stay unique (two sections with one title collide on Home).
  function takenTitles (except) {
    const titles = [...$sections.map(({ title }) => title), ...settings.customSections.map(([title]) => title), ...(settings.westernSections || []).map(([title]) => title)]
    return titles.filter(title => title !== except)
  }
  function addSection (key, entry) {
    settings[key] = [...(settings[key] || []), [uniqueSectionTitle('New Section', takenTitles()), ...entry]]
  }
  function renameSection (key, index, event) {
    const from = settings[key][index][0]
    const to = uniqueSectionTitle(event.currentTarget.value, takenTitles(from), from)
    event.currentTarget.value = to
    if (to === from) return
    settings[key][index][0] = to
    settings[key] = settings[key]
    settings.homeSections = renameHomeSection(settings.homeSections, from, to)
  }
  function removeSection (key, index) {
    const [title] = settings[key][index]
    settings[key].splice(index, 1)
    settings[key] = settings[key]
    if (![...settings.customSections, ...(settings.westernSections || [])].some(([other]) => other === title)) settings.homeSections = removeHomeSection(settings.homeSections, title)
  }
  const listStatus = [['Watching', 'CURRENT'], ['Planning', 'PLANNING'], ['Paused', 'PAUSED'], ['Completed', 'COMPLETED'], ['Dropped', 'DROPPED'], ['Rewatching', 'REPEATING'], ['Not on List', 'NOTONLIST']]

  // Discord account linked through the Discord Social SDK (Electron main process, see electron/src/main/discordSocial.js).
  /** @type {{ available: boolean, state: string, name: string, error: string }} */
  let discordAccount = { available: false, state: 'unavailable', name: '', error: '' }
  /** @type {Record<string, string>} */
  const discordAccountLabels = {
    unlinked: 'Not linked',
    linking: 'Linking…',
    connecting: 'Connecting…',
    linked: 'Linked, Rich Presence is disabled'
  }
  $: discordAccountText = discordAccount.state === 'connected' ? `Connected as ${discordAccount.name}` : (discordAccountLabels[discordAccount.state] || 'Not linked')
  if (SUPPORTS.discord) {
    IPC.invoke('discord-social:status').then((/** @type {any} */ status) => { if (status) discordAccount = status }).catch(() => {})
    IPC.on('discord-social:status', (/** @type {any} */ status) => { discordAccount = status })
    onDestroy(() => IPC.off('discord-social:status'))
  }
</script>

{#if SUPPORTS.discord}
  <h4 class='mb-10 font-weight-bold'>Rich Presence Settings</h4>
  <SettingCard title='Discord Rich Presence' description={'Enables the use of Discord rich presence to display app activity.\nFull enables complete rich presence support showing anime details, limited reduces what is seen not showing the currently played anime and episode, disabled completely disables rich presence.'}>
    <select class='form-control bg-dark w-100 mw-full text-truncate' bind:value={settings.enableRPC}>
      <option value='full' selected>Full</option>
      <option value='limited'>Limited</option>
      <option value='disabled'>Disabled</option>
    </select>
  </SettingCard>
  {#if discordAccount.available}
    <SettingCard title='Discord Account' description='Link your Discord account to show your activity even when the Discord app is closed. Without a linked account, rich presence only works while the Discord app is running.'>
      <div class='d-flex flex-column align-items-md-end w-200 mw-full'>
        <div class='font-weight-semi-bold text-truncate mw-full mb-5' title={discordAccountText}>{discordAccountText}</div>
        {#if discordAccount.state === 'unlinked'}
          <button type='button' use:click={() => IPC.emit('discord-social:link')} class='btn btn-primary d-flex align-items-center justify-content-center'><span class='text-truncate'>Link</span></button>
        {:else}
          <button type='button' use:click={() => IPC.emit('discord-social:unlink')} class='btn btn-danger d-flex align-items-center justify-content-center'><span class='text-truncate'>{discordAccount.state === 'linking' ? 'Cancel' : 'Unlink'}</span></button>
        {/if}
        {#if discordAccount.error}
          <div class='text-danger font-size-12 mt-5 pre-wrap text-md-right'>{discordAccount.error}</div>
        {/if}
      </div>
    </SettingCard>
  {/if}
  <SettingCard title='Second Discord Button' description={'The first button opens the title on AniList (or TMDB for shows and movies). During Watch Together, the second button is always "Join Watch Together".\nOutside Watch Together, choose what the second button opens.'}>
    <select class='form-control bg-dark w-100 mw-full text-truncate' bind:value={settings.rpcSecondButton}>
      <option value='mal' selected>MyAnimeList</option>
      <option value='download'>Download Tsumi</option>
    </select>
  </SettingCard>
  <SettingCard title='Adult Content on Discord' description={'What your Discord status shows while you watch adult content (hentai).\nHide the title shows "Watching something" without the title, cover or links, hide activity shows nothing, show normally shows it like anything else.'}>
    <select class='form-control bg-dark w-100 mw-full text-truncate' bind:value={settings.rpcHideAdult}>
      <option value='title' selected>Hide the title</option>
      <option value='hidden'>Hide activity</option>
      <option value='off'>Show normally</option>
    </select>
  </SettingCard>
{/if}

<h4 class='mb-10 font-weight-bold'>Interface Settings</h4>

<SettingCard title='Scale' description='Adjust the size of text, buttons, and other interface elements to match your preference and screen size.'>
  <div class='form-group w-160 flex-shrink-0 my-auto'>
    <input class='w-full p-2 bg-dark-light' type='range' id='ui-scale' min='0.5' max='2' step='0.05' bind:value={settings.uiScale} on:change={() => setScale()} />
    <div class='d-flex align-items-center justify-content-center gap-2 position-relative'>
      <strong>{Math.round(settings.uiScale * 100)}%</strong>
      <button type='button' use:click={() => { settings.uiScale = 1; setScale() }} class='btn btn-danger btn-square px-5 d-flex align-items-center position-absolute right-0' data-toggle='tooltip' data-placement='left' data-title='Reset To Default Interface Scaling' disabled={settings.uiScale === 1}><RotateCcw size='1.8rem' /></button>
    </div>
  </div>
</SettingCard>
<SettingCard title='CSS Variables' description='Used for custom themes. Can change colors, sizes, spacing and more. Supports only variables.{!SUPPORTS.isAndroid ? ' Best way to discover variables is to use the built-in devtools.' : ''}'>
  <div class='d-flex flex-column'>
    <textarea class='form-control w-md-500 w-full bg-dark' placeholder='--accent-color: #FFFFFF;' bind:value={$variables}></textarea>
    <button type='button' use:click={() => IPC.emit('ui-devtools')} class='btn btn-primary d-none align-items-center justify-content-center mt-10' class:d-flex={!SUPPORTS.isAndroid}><span class='text-truncate'>Open Devtools</span></button>
  </div>
</SettingCard>
<SettingCard title='Expandable Sidebar' description='Enables the sidebar to expand revealing detailed text for the navigation buttons.'>
  <div class='custom-switch'>
    <input type='checkbox' id='disable-sidebar' bind:checked={settings.expandingSidebar} />
    <label for='disable-sidebar'>{settings.expandingSidebar ? 'On' : 'Off'}</label>
  </div>
</SettingCard>
{#if SUPPORTS.isAndroid}
  <SettingCard title='Expandable Lists' description='Choose whether lists like recommendations or relations, open as dropdowns or scroll horizontally. Scrollable lists work better on smaller screens.'>
    <div class='custom-switch'>
      <input type='checkbox' id='toggle-list' bind:checked={settings.toggleList} />
      <label for='toggle-list'>{settings.toggleList ? 'On' : 'Off'}</label>
    </div>
  </SettingCard>
{/if}
{#if !Helper.isAniAuth()}
  <SettingCard title='Preferred Title Language' description='What title language to automatically select when displaying the title of an anime.'>
    <select class='form-control bg-dark mw-150 w-150' bind:value={settings.titleLang}>
      <option value='romaji' selected>Japanese</option>
      <option value='english'>English</option>
    </select>
  </SettingCard>
{/if}
<SettingCard title='Card Type' description='What type of cards to display in menus.'>
  <select class='form-control bg-dark w-100 mw-full text-truncate' bind:value={settings.cards}>
    <option value='small' selected>Small</option>
    <option value='full'>Full</option>
  </select>
</SettingCard>
{#if SUPPORTS.isAndroid && settings.cards === 'small'}
  <SettingCard title='Card Preview' description='If a detailed preview card should be shown when tapping or hovering over the small card.'>
    <div class='custom-switch'>
      <input type='checkbox' id='card-preview' bind:checked={settings.cardPreview} />
      <label for='card-preview'>{settings.cardPreview ? 'On' : 'Off'}</label>
    </div>
  </SettingCard>
{/if}
<SettingCard title='Card Audio' description={'If the sub, dub, partial dub, and age rating icons should be shown on the cards, the corresponding episode number will be shown when possible. Additionally a label will be shown on the preview cards, anime view, episode cards, and the home banner of the highest possible audio available, either dub, partial dub, or sub. Note these will not be visible when viewing the schedule page. '}>
  <div class='custom-switch'>
    <input type='checkbox' id='card-audio' bind:checked={settings.cardAudio} />
    <label for='card-audio'>{settings.cardAudio ? 'On' : 'Off'}</label>
  </div>
</SettingCard>
<SettingCard title='Prefer Dubs' description={'If your progress on a series matches the latest aired dubbed episode, the series will be hidden from Continue Watching until the next dub is available. Notifications will only be sent when a dubbed episode is released or if the series is sub-only (i.e., no dub exists).\n\nIf your progress goes beyond the latest dubbed episode, this setting will be ignored and the series will be treated as subbed. The Subbed Releases section will automatically hide dubbed series, and Dubbed Releases will hide subbed ones.\n\nThis setting is ideal for viewers who prefer dubbed content whenever available.'}>
  <div class='custom-switch'>
    <input type='checkbox' id='prefer-dubs' bind:checked={settings.preferDubs} />
    <label for='prefer-dubs'>{settings.preferDubs ? 'On' : 'Off'}</label>
  </div>
</SettingCard>
<SettingCard title='Adult Content' description='Adult enables searching for adult (18+) rated anime, typically series with nudity. Hentai enables searching straight up Hentai. This includes adding the Hentai home feed, Hentai genre, and Hentai related tags for search queries.'>
  <select class='form-control bg-dark w-100 mw-full text-truncate' bind:value={settings.adult}>
    <option value='none' selected>None</option>
    <option value='adult'>Adult</option>
    <option value='hentai'>Hentai</option>
  </select>
</SettingCard>
{#if settings.adult === 'hentai'}
  <SettingCard title='Hentai Banner' description='Changes the displayed series on the home page banner to be exclusively Hentai.'>
    <div class='custom-switch'>
      <input type='checkbox' id='hentai-banner' bind:checked={settings.hentaiBanner} />
      <label for='hentai-banner'>{settings.hentaiBanner ? 'On' : 'Off'}</label>
    </div>
  </SettingCard>
{/if}
<SpoilerSettings bind:settings />
{#if SUPPORTS.angle}
  <h4 class='mb-10 font-weight-bold'>Rendering Settings</h4>
  <SettingCard title='ANGLE Backend' description="What ANGLE backend to use for rendering. DON'T CHANGE WITHOUT REASON! On some Windows machines D3D9 might help with flicker. Changing this setting to something your device doesn't support might prevent Tsumi from opening which will require a full reinstall. While Vulkan is an available option it might not be fully supported on Linux.">
    <select class='form-control bg-dark w-300 mw-full text-truncate' bind:value={settings.angle} on:change={updateAngle}>
      <option value='default' selected>Default</option>
      <option value='d3d9'>D3D9</option>
      <option value='d3d11'>D3D11</option>
      <option value='warp'>Warp [Software D3D11]</option>
      <option value='gl'>GL</option>
      <option value='gles'>GLES</option>
      <option value='swiftshader'>SwiftShader</option>
      <option value='vulkan'>Vulkan</option>
      <option value='metal'>Metal</option>
    </select>
  </SettingCard>
{/if}
<h4 class='mb-10 font-weight-bold'>Notification Settings</h4>
<SettingCard title='System Notifications' description='Allows custom system notifications to be sent, with this disabled you will still get in-app notifications. If you enable system notifications and have MULTIPLE Notification Feeds specified, such as Releases and Anilist you WILL be spammed with multiple notifications. Consider choosing a single feed based on your needs.'>
  <div class='custom-switch'>
    <input type='checkbox' id='system-notify' bind:checked={settings.systemNotify} />
    <label for='system-notify'>{settings.systemNotify ? 'On' : 'Off'}</label>
  </div>
</SettingCard>
{#if Helper.isAniAuth()}
  <SettingCard title='AniList Notifications' description='Get notifications from your AniList account, showing when episodes have aired and any new anime titles you are following have been added to the database. Limited will only get important notifications like when a new season is announced.'>
    <select class='form-control bg-dark w-120 mw-120 mw-full text-truncate' bind:value={settings.aniNotify}>
      <option value='all' selected>All</option>
      <option value='limited'>Limited</option>
      <option value='none'>None</option>
    </select>
  </SettingCard>
{/if}
{#each ['Sub', 'Dub', 'Hentai', 'Western'] as type}
  {#if type !== 'Hentai' || settings.adult === 'hentai'}
    <SettingCard title='{type} Announcements' description={`Get ${type} announcement notifications when an airing date is confirmed. Choose to get all announcements, updates on sequels for related anime you're following, or turn off notifications entirely.`}>
      <select class='form-control bg-dark w-120 mw-120 text-truncate' bind:value={settings[`${type.toLowerCase()}Announce`]}>
        <option value='all' selected>All</option>
        <option value='following' selected>Following</option>
        <option value='none'>None</option>
      </select>
    </SettingCard>
  {/if}
{/each}
<SettingCard title='Releases Notifications' description='When a new episode is added to any of the Releases feeds, a notification will be sent depending on your list status.'>
  <div>
    {#each settings.releasesNotify as status, i}
      <div class='input-group mb-10 w-210 mw-full'>
        <select id='dubs-notify-{i}' class='w-100 form-control mw-full bg-dark text-truncate' bind:value={settings.releasesNotify[i]}>
          <option disabled value=''>Select a status</option>
          {#each listStatus.filter(option => !settings.releasesNotify.includes(option[1]) || status === option[1]) as option}
            <option value={option[1]}>{option[0]}</option>
          {/each}
        </select>
        <div class='input-group-append'>
          <button type='button' use:click={() => { settings.releasesNotify.splice(i, 1); settings.releasesNotify = settings.releasesNotify }} class='btn btn-danger btn-square input-group-append px-5 d-flex align-items-center'><Trash2 size='1.8rem' /></button>
        </div>
      </div>
    {/each}
    <button type='button' disabled={listStatus.every(option => settings.releasesNotify.includes(option[1]))} use:click={() => { settings.releasesNotify = [...settings.releasesNotify, ''] }} class='btn btn-primary mb-10 mr-10 d-flex align-items-center justify-content-center'><span>Add Status</span></button>
  </div>
</SettingCard>
<MovieAlertsSettings />

<h4 class='mb-10 font-weight-bold'>Home Screen Settings</h4>
{#if Helper.isAuthorized()}
  <SettingCard title='Hide My Anime' description='The anime on your Watching, Rewatching, Completed, and Dropped list will automatically be hidden from the default sections, this excludes user specific feeds.'>
    <div class='custom-switch'>
      <input type='checkbox' id='hide-my-anime' bind:checked={settings.hideMyAnime} />
      <label for='hide-my-anime'>{settings.hideMyAnime ? 'On' : 'Off'}</label>
    </div>
  </SettingCard>
{/if}
<SettingCard title='Hero Content' description='What content to display on the home screen hero banner section. Balanced interleaves trending Anime and Western media, while the others restrict it to a single source.'>
  <select class='form-control bg-dark w-150 mw-full text-truncate' bind:value={settings.bannerProvider}>
    <option value='mix' selected>Balanced (50/50)</option>
    <option value='anime'>Anime (AniList)</option>
    <option value='western'>Western (TMDB)</option>
  </select>
</SettingCard>
<SettingCard title='Anime Sections' description='Create custom anime sections that can be added to the home screen. These use AniList genres and tags.'>
  <div>
    {#each settings.customSections as _, i}
      {#if i === 0}
        <div class='d-flex mb-5 w-480 mw-full'>
          <div class='flex-shrink-1 w-150 font-size-16 text-center font-weight-bold'>Name</div>
          <div class='flex-shrink-1 w-150 font-size-16 text-center font-weight-bold'>Genres</div>
          <div class='flex-shrink-1 w-150 mr-5 font-size-16 text-center font-weight-bold'>Tags</div>
          <div class='flex-shrink-1 w-30 font-size-16 text-center font-weight-bold hidden'>&nbsp;</div>
        </div>
      {/if}
      <div class='d-flex mb-10 w-480 mw-full'>
        <div class='position-relative flex-shrink-1 w-150'>
          <input
            type='text'
            class='form-control bg-dark fix-border-right text-capitalize text-truncate'
            placeholder='Name'
            autocomplete='off'
            value={settings.customSections[i][0]}
            on:change={(event) => renameSection('customSections', i, event)}
          />
        </div>
        <div class='position-relative flex-shrink-1 w-150'>
          <CustomDropdown id={`genre-is-${i}`} options={genreList} bind:value={settings.customSections[i][1]} disabled={settings.customSections[i][1]?.includes('N/A')} />
        </div>
        <div class='position-relative flex-shrink-1 w-150'>
          <CustomDropdown id={`tag-is-${i}`} options={tagList} bind:value={settings.customSections[i][2]} disabled={settings.customSections[i][2]?.includes('N/A')} />
        </div>
        <div class='input-group-append'>
          <button type='button' use:click={() => removeSection('customSections', i)} class='btn btn-danger btn-square input-group-append px-5 d-flex align-items-center'><Trash2 size='1.8rem' /></button>
        </div>
      </div>
    {/each}
    <button type='button' use:click={() => addSection('customSections', [[], [], [], []])} class='btn btn-primary mb-10 d-flex align-items-center justify-content-center'><span>Add Section</span></button>
  </div>
</SettingCard>
<SettingCard title='Western Sections (TMDB)' description='Create custom western media sections powered by TMDB. These filter out anime and use TMDB genres.'>
  <div>
    {#each (settings.westernSections || []) as _, i}
      {#if i === 0}
        <div class='d-flex mb-5 w-500 mw-full'>
          <div class='flex-shrink-1 w-150 font-size-16 text-center font-weight-bold'>Name</div>
          <div class='flex-shrink-1 w-200 font-size-16 text-center font-weight-bold'>Genres</div>
          <div class='flex-shrink-1 w-120 mr-5 font-size-16 text-center font-weight-bold'>Type</div>
          <div class='flex-shrink-1 w-30 font-size-16 text-center font-weight-bold hidden'>&nbsp;</div>
        </div>
      {/if}
      <div class='d-flex mb-10 w-500 mw-full'>
        <div class='position-relative flex-shrink-1 w-150'>
          <input
            type='text'
            class='form-control bg-dark fix-border-right text-capitalize text-truncate'
            placeholder='Name'
            autocomplete='off'
            value={settings.westernSections[i][0]}
            on:change={(event) => renameSection('westernSections', i, event)}
          />
        </div>
        <div class='position-relative flex-shrink-1 w-200'>
          <CustomDropdown id={`tmdb-genre-${i}`} options={tmdbGenreList} bind:value={settings.westernSections[i][1]} />
        </div>
        <div class='position-relative flex-shrink-1 w-120'>
          <select class='form-control bg-dark mw-full text-truncate' bind:value={settings.westernSections[i][2]}>
            <option value='Both'>Both</option>
            <option value='TV Shows'>TV Shows</option>
            <option value='Movies'>Movies</option>
          </select>
        </div>
        <div class='input-group-append'>
          <button type='button' use:click={() => removeSection('westernSections', i)} class='btn btn-danger btn-square input-group-append px-5 d-flex align-items-center'><Trash2 size='1.8rem' /></button>
        </div>
      </div>
    {/each}
    <button type='button' use:click={() => addSection('westernSections', [[], 'Both'])} class='btn btn-primary mb-10 d-flex align-items-center justify-content-center'><span>Add Section</span></button>
  </div>
</SettingCard>
<SettingCard title='Sections And Order' description='Sections and their order on the home screen. Custom Anime and Western sections created above can be added here. Drag/drop these sections to re-order them.'>
  <div class='position-relative'>
    <HomeSections bind:homeSections={settings.homeSections} />
  </div>
</SettingCard>

<style>
  .w-210 {
    width: 21rem;
  }
  .w-480 {
    width: 48rem;
  }
  .w-500 {
    width: 50rem;
  }
  .w-200 {
    width: 20rem;
  }
  .w-120 {
    width: 12rem;
  }
  textarea {
    min-height: 6.6rem;
  }
  .fix-border-right {
    border-top-right-radius: 0 !important;
    border-bottom-right-radius: 0 !important;
  }
</style>
