<script>
  import { manager } from '@/modules/extension.js'
  import { linksResults } from '@/modules/sora/moduleresult.js'

  /** "Link results to AniList / TMDB" of a Sora module (Extensions tab): off, its results open as they are. */
  export let extensionKey
  /** the module entry of settings.extensions */
  export let config
</script>

<div class='mt-10'>
  <div class='custom-switch'>
    <input type='checkbox' id={`extension-link-${extensionKey}`} checked={linksResults(config)} on:change={(event) => manager.setLinkResults(extensionKey, event.currentTarget.checked)} />
    <label for={`extension-link-${extensionKey}`} class='font-scale-14'>Link results to AniList / TMDB</label>
  </div>
  <div class='text-muted font-scale-12 mt-5'>Off: results of this module open as they are, with its own episodes and no list tracking. For modules that are not anime, shows or movies.</div>
</div>
