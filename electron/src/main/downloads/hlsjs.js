// The hls.js library the player runs in the app page (common/modules/streaming.js), pinned to one exact file.
// Pure (node:crypto only), tested by hlsjs.test.mjs.
import { createHash } from 'node:crypto'

/** hls.js 1.4.5, the file the player loads from the CDN (HLS_JS_URL in common/modules/streaming.js, same value). */
export const HLS_JS_URL = 'https://cdn.jsdelivr.net/npm/hls.js@1.4.5/dist/hls.min.js'

/**
 * SHA-384 (base64) of that file, the same as dist/hls.min.js of the npm package hls.js@1.4.5. The renderer has the
 * browser check it (Subresource Integrity, HLS_JS_INTEGRITY in streaming.js); here it checks the offline copy of the
 * downloads before it is saved and each time it is served, since that copy runs in the page that has the IPC bridge.
 */
export const HLS_JS_SHA384 = 'GuEz/RD9TfqZhxw9UmeaUmXVz/VDbz+NxBf7oRFs1rrMHPPA429NgphPL6PvdviR'

/** True when `data` is exactly the pinned hls.js file. */
export function isPinnedHlsJs (data) {
  if (!data || !data.length) return false
  return createHash('sha384').update(data).digest('base64') === HLS_JS_SHA384
}
