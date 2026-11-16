import SectionsManager from '@/modules/sections.js'
import { extensionManager } from '@/modules/extension.js'
import { listCatalogs, loadCatalogPage, catalogSupports } from '@/modules/stremio.js'
import { writable } from 'simple-store-svelte'

// Sections of the Stremio addon catalogs: the rows of the Catalogs page (CatalogPage.svelte) and the catalogs of
// the Source menu of the search page (SearchBar.svelte), which opens one in full.

export const typeLabel = (type) => type === 'movie' ? 'Movies' : type === 'series' ? 'Series' : type

/** Enabled Stremio addons (Sora modules have no catalogs). */
export function catalogAddons () {
  return extensionManager.getEnabled().filter(ext => ext.type === 'stremio')
}

function makeSection (ext, catalog, extra, title) {
  const key = `${ext.key}|${catalog.type}|${catalog.id}|${extra.search || ''}`
  // Title field of the search page: searched in the catalog itself when it can search, else in a search catalog of
  // the addon for the same type (none: the field is disabled, SearchBar.svelte).
  const searchCatalog = catalogSupports(catalog, 'search') ? catalog : listCatalogs(ext, { search: true }).find(other => other.type === catalog.type)
  return {
    key,
    title,
    load: (pageNumber = 1, perPage = 50, variables = null) => {
      const query = typeof variables?.search === 'string' ? variables.search.trim() : ''
      if (query && searchCatalog) return SectionsManager.wrapResponse(loadCatalogPage(ext, searchCatalog, pageNumber, perPage, { ...extra, search: query }), perPage)
      return SectionsManager.wrapResponse(loadCatalogPage(ext, catalog, pageNumber, perPage, extra), perPage)
    },
    preview: writable(),
    // Variables of the search page once the section is opened ("See all"): catalogKey selects it in Source.
    variables: { stremioCatalog: true, catalogKey: key, catalogSearch: !!searchCatalog }
  }
}

/**
 * Catalog sections of the addons, or with `search` one searchable catalog per type and addon.
 * @param {any[]} addons
 * @param {string} [search]
 */
export function catalogSections (addons, search) {
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
