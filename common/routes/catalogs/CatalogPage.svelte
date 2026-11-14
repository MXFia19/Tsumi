<script>
  import HomeSection from '@/routes/home/components/HomeSection.svelte'
  import SectionsManager from '@/modules/sections.js'
  import { manager, extensionManager } from '@/modules/extension.js'
  import { listCatalogs, loadCatalogPage } from '@/modules/stremio.js'
  import { page } from '@/modules/navigation.js'
  import { click } from '@/modules/click.js'
  import { writable } from 'simple-store-svelte'
  import { onDestroy } from 'svelte'
  import { Clapperboard, Search, X, TriangleAlert } from 'lucide-svelte'

  // Enabled Stremio addons (Sora modules have no catalogs).
  let addons = []
  const unsubscribe = manager.subscribe(() => {
    addons = extensionManager.getEnabled().filter(ext => ext.type === 'stremio')
  })
  onDestroy(unsubscribe)

  let query = ''
  let activeQuery = ''
  let debounceTimer
  function onInput () {
    clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => { activeQuery = query.trim() }, 500)
  }
  function clearSearch () {
    clearTimeout(debounceTimer)
    query = ''
    activeQuery = ''
  }
  onDestroy(() => clearTimeout(debounceTimer))

  const typeLabel = (type) => type === 'movie' ? 'Movies' : type === 'series' ? 'Series' : type

  function makeSection (ext, catalog, extra, title) {
    return {
      key: `${ext.key}|${catalog.type}|${catalog.id}|${extra.search || ''}`,
      title,
      load: (pageNumber = 1, perPage = 50) => SectionsManager.wrapResponse(loadCatalogPage(ext, catalog, pageNumber, perPage, extra), perPage),
      preview: writable(),
      variables: { stremioCatalog: true }
    }
  }

  function buildSections (addons, search) {
    const sections = []
    const several = addons.length > 1
    for (const ext of addons) {
      const addonName = ext.manifest?.sourceName || ext.key
      if (search) {
        // One searchable catalog per type is enough (they search the same library).
        const seenTypes = new Set()
        for (const catalog of listCatalogs(ext, { search: true })) {
          if (seenTypes.has(catalog.type)) continue
          seenTypes.add(catalog.type)
          sections.push(makeSection(ext, catalog, { search }, `${typeLabel(catalog.type)} · ${addonName}`))
        }
      } else {
        for (const catalog of listCatalogs(ext)) {
          const name = catalog.name || typeLabel(catalog.type)
          sections.push(makeSection(ext, catalog, {}, several ? `${name} · ${addonName}` : name))
        }
      }
    }
    return sections
  }

  $: sections = buildSections(addons, activeQuery)
  $: canSearch = addons.some(ext => listCatalogs(ext, { search: true }).length > 0)
</script>

<div class='h-full w-full overflow-y-scroll root overflow-x-hidden'>
  <div class='d-flex flex-column w-full mt-15 pl-sm-30 pl-md-80'>
    <div class='d-flex align-items-center flex-wrap px-20 pt-20 pb-10 header'>
      <Clapperboard size='2.6rem' class='mr-10 flex-shrink-0' />
      <h3 class='m-0 font-weight-bold'>Catalogs</h3>
      {#if canSearch}
        <div class='search-box d-flex align-items-center ml-md-auto mt-10 mt-md-0 position-relative'>
          <Search size='1.8rem' class='position-absolute search-icon' color='var(--gray-color-very-dim)' />
          <input
            type='text'
            class='form-control bg-dark-light rounded-2 h-36 border pl-40 pr-40'
            placeholder='Search in your addons'
            bind:value={query}
            on:input={onInput}
            on:keydown={(e) => { if (e.key === 'Enter') { clearTimeout(debounceTimer); activeQuery = query.trim() } }} />
          {#if query}
            <button type='button' class='btn btn-square bg-transparent shadow-none border-0 p-0 position-absolute clear-btn' title='Clear search' use:click={clearSearch}>
              <X size='1.6rem' />
            </button>
          {/if}
        </div>
      {/if}
    </div>

    {#if !addons.length}
      <div class='card m-20 p-15 bg-dark-light border wm-800'>
        <div class='d-flex'>
          <TriangleAlert size='4.3rem' class='flex-shrink-0' />
          <div class='ml-10'>
            <div class='font-size-18 font-weight-bold'>No Stremio addon</div>
            <div class='text-muted pre-wrap'>Add a Stremio addon in Settings &gt; Extensions by pasting the URL of its manifest.json. Its catalogs will show up here.</div>
            <button type='button' class='btn btn-primary rounded-2 mt-10 px-15 h-36' use:click={() => page.navigateTo(page.SETTINGS)}>Open Settings</button>
          </div>
        </div>
      </div>
    {:else if !sections.length}
      <div class='text-muted px-20 py-10'>{activeQuery ? 'None of your addons can search.' : 'Your Stremio addons have no catalogs to browse.'}</div>
    {:else}
      {#each sections as opts (opts.key)}
        <HomeSection {opts} />
      {/each}
    {/if}
  </div>
</div>

<style>
  .search-box {
    width: 32rem;
    max-width: 100%;
  }
  .search-box input {
    width: 100%;
  }
  .search-box :global(.search-icon) {
    left: 1rem;
    pointer-events: none;
  }
  .clear-btn {
    right: 1rem;
  }
  .pl-40 {
    padding-left: 4rem !important;
  }
  .pr-40 {
    padding-right: 4rem !important;
  }
</style>
