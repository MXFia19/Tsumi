<script context='module'>
  export const TABS = {}
</script>

<script>
  import { setContext, onDestroy, onMount } from 'svelte'
  import { writable } from 'simple-store-svelte'

  /** Index of the tab selected first (SettingsPage: the last one opened) */
  export let initial = 0
  /** @type {((index: number) => void) | null} Called when a tab is selected */
  export let onSelect = null

  const tabs = []
  const panels = []
  const selectedTab = writable(null)
  const selectedPanel = writable(null)

  // While the tabs register, only the initial one is selected: selecting the first one meanwhile created its content
  // and destroyed it in the same update when another tab was the initial one, and the binding of that destroyed
  // content (SettingsPage: bind:settings) handed undefined to the settings store. The first tab is the fallback once
  // they are all registered (onMount).
  setContext(TABS, {
    registerTab: tab => {
      tabs.push(tab)
      if (tabs.length - 1 === initial) selectedTab.set(tab)

      onDestroy(() => {
        const i = tabs.indexOf(tab)
        tabs.splice(i, 1)
        selectedTab.update(current => (current === tab ? tabs[i] || tabs[tabs.length - 1] : current))
      })
    },

    registerPanel: panel => {
      panels.push(panel)
      if (panels.length - 1 === initial) selectedPanel.set(panel)

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

  onMount(() => {
    if (!selectedTab.value) selectedTab.set(tabs[0] || null)
    if (!selectedPanel.value) selectedPanel.set(panels[0] || null)
  })
</script>

<slot></slot>
