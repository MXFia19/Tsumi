<script context='module'>
  export const TABS = {}
</script>

<script>
  import { setContext, onDestroy } from 'svelte'
  import { writable } from 'simple-store-svelte'

  /** Index of the tab selected first (SettingsPage: the last one opened) */
  export let initial = 0
  /** @type {((index: number) => void) | null} Called when a tab is selected */
  export let onSelect = null

  const tabs = []
  const panels = []
  const selectedTab = writable(null)
  const selectedPanel = writable(null)

  setContext(TABS, {
    registerTab: tab => {
      tabs.push(tab)
      selectedTab.update(current => (tabs.length - 1 === initial ? tab : current || tab))

      onDestroy(() => {
        const i = tabs.indexOf(tab)
        tabs.splice(i, 1)
        selectedTab.update(current => (current === tab ? tabs[i] || tabs[tabs.length - 1] : current))
      })
    },

    registerPanel: panel => {
      panels.push(panel)
      selectedPanel.update(current => (panels.length - 1 === initial ? panel : current || panel))

      onDestroy(() => {
        const i = panels.indexOf(panel)
        panels.splice(i, 1)
        selectedPanel.update(current => (current === panel ? panels[i] || panels[panels.length - 1] : current))
      })
    },

    selectTab: tab => {
      const i = tabs.indexOf(tab)
      selectedTab.set(tab)
      selectedPanel.set(panels[i])
      onSelect?.(i)
    },

    selectedTab,
    selectedPanel
  })
</script>

<slot></slot>
