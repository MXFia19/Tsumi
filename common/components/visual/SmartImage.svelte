<script>
  export let images = []
  export let hidden = false
  export let color = null
  export let title = ''

  let index = 0
  let resolvedImages = []
  let failed = false
  $: if (images) { index = 0; resolvedImages = []; failed = false }
  $: filteredImages = images.filter(Boolean)
  $: loadNextImage(index, filteredImages)
  async function loadNextImage (index, filteredImages) {
    let image
    try {
      // Sources can be URLs, promises, functions (lazy) or arrays of those: resolve until this slot holds a URL.
      // An empty array removes its slot, so the next source (maybe another function) must be resolved too.
      for (let attempts = 0; attempts < 10; attempts++) {
        image = filteredImages[index]
        if (typeof image === 'function') image = image()
        if (image && typeof image.then === 'function') image = await image
        if (!Array.isArray(image)) break
        filteredImages.splice(index, 1, ...image.filter(Boolean))
      }
    } catch { image = `${index}_404.jpg` }
    resolvedImages[index] = typeof image === 'string' ? image : undefined
  }
  function handleError () {
    if (index < filteredImages.filter(Boolean).length - 1) index += 1
    else failed = true
  }
  function validate (event) {
    const image = event.target
    if (/ytimg\.com|youtube\.com|youtube-nocookie\.com|youtu\.be/i.test(image.currentSrc || image.src) && image.naturalWidth === 120 && image.naturalHeight === 90) handleError()
  }
</script>
<img class={$$restProps.class ? $$restProps.class.split(' ').filter(_class => (_class !== 'cover-rotated' && _class !== 'cr-380' && _class !== 'cr-400') || !resolvedImages[index]?.includes('404')).join(' ') : ''} style={(color ? `--color: ${color};` : '')} class:d-none={hidden || failed} src={!hidden && !failed ? (resolvedImages[index] || `${index}_404.jpg`) : `${index}_404.jpg`} alt='preview' {title} draggable='false' loading='lazy' referrerpolicy='no-referrer' on:error={handleError} on:load={validate} />
