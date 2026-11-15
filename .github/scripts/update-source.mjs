// Adds a release to the Feather / AltStore source (docs/source.json, served by GitHub Pages).
// Usage: node .github/scripts/update-source.mjs <source.json> <release.json> <owner/repo> [version]
// release.json is the output of: gh release view <tag> --json tagName,publishedAt,body,assets
// version defaults to the tag without its "v" (it must be the CFBundleShortVersionString of the IPA).
// The newest version comes first in versions[] (AltStore and Feather read the first one); the legacy single-version
// fields of the app (version, versionDate, downloadURL, size...) are kept in sync for older source readers.
import { readFileSync, writeFileSync } from 'node:fs'

const BUNDLE_ID = 'org.tsumi.app'
const IPA_NAME = 'Tsumi.ipa'
const MIN_OS_VERSION = '17.0'
const KEEP_VERSIONS = 10

const [sourcePath, releasePath, repository, versionArgument] = process.argv.slice(2)
if (!sourcePath || !releasePath || !repository) {
  console.error('Usage: node update-source.mjs <source.json> <release.json> <owner/repo>')
  process.exit(2)
}

const source = JSON.parse(readFileSync(sourcePath, 'utf8'))
const release = JSON.parse(readFileSync(releasePath, 'utf8'))

const tag = String(release.tagName || '')
const version = versionArgument || tag.replace(/^v/, '')
if (!/^\d+(\.\d+){1,3}$/.test(version)) {
  console.error(`${version} (tag ${tag}) is not a version (X.Y.Z)`)
  process.exit(1)
}
const ipa = (release.assets || []).find(asset => asset.name === IPA_NAME)
if (!ipa) {
  console.error(`Release ${tag} has no ${IPA_NAME}`)
  process.exit(1)
}
const app = (source.apps || []).find(entry => entry.bundleIdentifier === BUNDLE_ID)
if (!app) {
  console.error(`${sourcePath} has no app ${BUNDLE_ID}`)
  process.exit(1)
}

// Release notes are Markdown; sources show plain text.
const notes = String(release.body || '')
  .replace(/\r\n/g, '\n')
  .replace(/<!--[\s\S]*?-->/g, '')
  .replace(/^#{1,6}\s+/gm, '')
  .replace(/\*\*(.+?)\*\*/g, '$1')
  .replace(/\n{3,}/g, '\n\n')
  .trim()
  .slice(0, 4000)

const entry = {
  version,
  date: (release.publishedAt || new Date().toISOString()).replace(/\.\d+Z$/, 'Z'),
  localizedDescription: notes || `Tsumi ${tag}`,
  downloadURL: `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/${IPA_NAME}`,
  size: Number(ipa.size) || 0,
  minOSVersion: MIN_OS_VERSION
}

app.versions = [entry, ...(app.versions || []).filter(old => old.version !== version)]
  .sort((a, b) => compareVersions(b.version, a.version))
  .slice(0, KEEP_VERSIONS)

const latest = app.versions[0]
app.version = latest.version
app.versionDate = latest.date
app.versionDescription = latest.localizedDescription
app.downloadURL = latest.downloadURL
app.size = latest.size

writeFileSync(sourcePath, JSON.stringify(source, null, 2) + '\n')
console.log(`${sourcePath}: ${app.name} ${latest.version} (${latest.size} bytes) ${latest.downloadURL}`)

function compareVersions (a, b) {
  const left = String(a).split('.').map(Number)
  const right = String(b).split('.').map(Number)
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const diff = (left[i] || 0) - (right[i] || 0)
    if (diff) return diff
  }
  return 0
}
