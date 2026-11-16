<script>
  import { createEventDispatcher, onDestroy } from 'svelte'
  import { ChevronDown, ChevronRight, Check } from 'lucide-svelte'

  // Source menu of the search page (SearchBar.svelte): Both / Anime / Western, then collapsible groups (the catalogs
  // of each Stremio addon, the Sora modules). A native <select> cannot fold its groups, and dozens of catalogs made
  // the list very long. Groups start folded, except the one holding the current source.

  /** @type {string} */
  export let value
  /** @type {{ id: string, label?: string, items: { value: string, label: string }[] }[]} */
  export let groups = []
  export let disabled = false

  const dispatch = createEventDispatcher()
  let open = false
  let root
  let menu
  const expanded = {}

  $: currentLabel = groups.flatMap(group => group.items).find(item => item.value === value)?.label || 'Both'

  function toggleOpen () {
    if (disabled) return
    open = !open
    if (open) {
      for (const group of groups) {
        if (group.label && group.items.some(item => item.value === value)) expanded[group.id] = true
      }
      // Focus the current option so the keyboard / D-pad starts there.
      setTimeout(() => menu?.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ block: 'nearest' }))
    }
  }

  function toggleGroup (id) {
    expanded[id] = !expanded[id]
  }

  function pick (item) {
    open = false
    if (item.value !== value) dispatch('change', item.value)
  }

  function onPointerDown (event) {
    if (open && root && !root.contains(event.target)) open = false
  }

  function onKeyDown (event) {
    if (event.key === 'Escape' && open) {
      open = false
      event.stopPropagation()
      event.preventDefault()
    }
  }

  window.addEventListener('pointerdown', onPointerDown, true)
  onDestroy(() => window.removeEventListener('pointerdown', onPointerDown, true))
</script>

<!-- svelte-ignore a11y-no-static-element-interactions -->
<div class='position-relative w-full' bind:this={root} on:keydown={onKeyDown}>
  <button type='button' class='form-control bg-dark-light rounded-1 d-flex align-items-center text-left source-button' aria-haspopup='listbox' aria-expanded={open} {disabled} on:click|preventDefault={toggleOpen}>
    <span class='text-truncate flex-grow-1'>{currentLabel}</span>
    <ChevronDown size='1.6rem' class='flex-shrink-0 ml-5' />
  </button>
  {#if open}
    <div class='source-menu position-absolute bg-dark-light rounded-1 overflow-y-auto' role='listbox' bind:this={menu}>
      {#each groups as group (group.id)}
        {#if group.label}
          <button type='button' class='group-header d-flex align-items-center w-full' aria-expanded={!!expanded[group.id]} on:click|preventDefault={() => toggleGroup(group.id)}>
            {#if expanded[group.id]}
              <ChevronDown size='1.6rem' class='flex-shrink-0' />
            {:else}
              <ChevronRight size='1.6rem' class='flex-shrink-0' />
            {/if}
            <span class='ml-5 text-truncate'>{group.label}</span>
            <span class='ml-auto pl-10 text-muted font-size-12'>{group.items.length}</span>
          </button>
        {/if}
        {#if !group.label || expanded[group.id]}
          {#each group.items as item (item.value)}
            <button type='button' role='option' aria-selected={item.value === value} class='option d-flex align-items-center w-full' class:indent={!!group.label} class:selected={item.value === value} on:click|preventDefault={() => pick(item)}>
              <span class='text-truncate'>{item.label}</span>
              {#if item.value === value}
                <Check size='1.4rem' class='flex-shrink-0 ml-auto pl-5' />
              {/if}
            </button>
          {/each}
        {/if}
      {/each}
    </div>
  {/if}
</div>

<style>
  .source-button {
    cursor: pointer;
    min-width: 12rem;
  }
  .source-menu {
    top: calc(100% + .4rem);
    left: 0;
    z-index: 60;
    min-width: 100%;
    width: max-content;
    max-width: 38rem;
    max-height: 60vh;
    padding: .4rem 0;
    border: 1px solid hsla(var(--white-color-hsl), 0.1);
    box-shadow: 0 1rem 3rem rgba(0, 0, 0, 0.6);
  }
  .option, .group-header {
    background: transparent;
    border: 0;
    color: inherit;
    text-align: left;
    padding: .55rem 1.2rem;
    font-size: 1.4rem;
    white-space: nowrap;
    cursor: pointer;
  }
  .group-header {
    font-weight: 600;
    color: var(--gray-color-very-dim, inherit);
    margin-top: .2rem;
  }
  .option.indent {
    padding-left: 3.2rem;
  }
  .option.selected {
    font-weight: 600;
  }
  .option:hover, .option:focus-visible, .group-header:hover, .group-header:focus-visible {
    background: hsla(var(--white-color-hsl), 0.08);
    outline: none;
  }
</style>
