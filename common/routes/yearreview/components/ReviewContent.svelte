<script>
  import SmartImage from '@/components/visual/SmartImage.svelte'
  import MonthChart from '@/routes/yearreview/components/MonthChart.svelte'
  import { hoursValue, formatNumber, formatDay, dayKey, MONTH_NAMES } from '@/modules/yearreview/stats.js'
  import { Flame, Play, Flag, Star, Tv } from 'lucide-svelte'

  /** @type {{ year: number, stats: any, media: Record<number, any>, fetchedAt: number, local: any }} */
  export let review
  /** @type {{ name: string, avatar: string | null }} */
  export let account
  /** Only the local history section (the AniList year is empty). */
  export let localOnly = false

  function lookup (map, id) {
    return map?.[id] || { title: 'Unknown title' }
  }
  function plural (value, word) {
    return `${formatNumber(value)} ${word}${value === 1 ? '' : 's'}`
  }
  function dateOf (seconds) {
    return seconds ? formatDay(dayKey(seconds)) : ''
  }

  $: stats = review.stats
  $: hero = stats.topAnime[0] ? lookup(review.media, stats.topAnime[0].mediaId) : null
  $: bestMonth = stats.months.indexOf(Math.max(...stats.months))
  $: maxGenre = Math.max(1, ...stats.genres.map(genre => genre.count))
  $: updated = new Date(review.fetchedAt * 1000).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
</script>

{#if !localOnly}
  <section class='hero position-relative overflow-hidden'>
    {#if hero?.banner || hero?.cover}
      <div class='hero-image position-absolute' style='background-image: url("{hero.banner || hero.cover}")'></div>
    {/if}
    <div class='hero-content position-relative d-flex flex-column flex-md-row align-items-md-end justify-content-between'>
      <div>
        <div class='eyebrow font-weight-bold'>YEAR IN REVIEW</div>
        <h1 class='font-weight-very-bold m-0 mt-5'>Your {review.year} in anime</h1>
        <div class='d-flex align-items-center mt-10 text-muted font-size-16'>
          {#if account.avatar}
            <img class='avatar rounded-circle mr-10' src={account.avatar} alt='' referrerpolicy='no-referrer' />
          {/if}
          {account.name}
        </div>
      </div>
      <div class='big-numbers d-flex mt-20 mt-md-0'>
        <div class='big'>
          <div class='big-value'>{formatNumber(stats.episodes)}</div>
          <div class='big-label'>episodes</div>
        </div>
        <div class='big'>
          <div class='big-value'>{formatNumber(hoursValue(stats.minutes))}</div>
          <div class='big-label'>hours</div>
        </div>
        <div class='big'>
          <div class='big-value'>{formatNumber(stats.titles)}</div>
          <div class='big-label'>anime</div>
        </div>
      </div>
    </div>
  </section>

  <section class='grid-cards'>
    <div class='card-box'>
      <div class='card-value'>{formatNumber(stats.started)}</div>
      <div class='card-label'>anime started</div>
    </div>
    <div class='card-box'>
      <div class='card-value'>{formatNumber(stats.completed)}</div>
      <div class='card-label'>completed</div>
    </div>
    <div class='card-box'>
      <div class='card-value'>{formatNumber(stats.dropped)}</div>
      <div class='card-label'>dropped</div>
    </div>
    <div class='card-box'>
      <div class='card-value'>{stats.averageScore !== null ? stats.averageScore : '–'}<span class='card-unit'>{stats.averageScore !== null ? ' / 10' : ''}</span></div>
      <div class='card-label'>average score{stats.scoredCount ? ` (${plural(stats.scoredCount, 'rating')})` : ''}</div>
    </div>
    <div class='card-box'>
      <div class='card-value'>{formatNumber(stats.activeDays)}</div>
      <div class='card-label'>days with anime</div>
    </div>
    <div class='card-box'>
      <div class='card-value'>{formatNumber(stats.longestStreak?.days || 0)}</div>
      <div class='card-label'>longest daily streak</div>
    </div>
  </section>

  {#if stats.topAnime.length}
    <section class='panel'>
      <h2 class='panel-title'>Top anime</h2>
      <div class='top-row d-flex'>
        {#each stats.topAnime as item, index (item.mediaId)}
          {@const entry = lookup(review.media, item.mediaId)}
          <div class='top-item'>
            <div class='cover-wrap position-relative'>
              <SmartImage class='cover w-full h-full' images={[entry.cover, './404_cover.png']} title={entry.title} />
              <div class='rank position-absolute font-weight-very-bold' class:first={index === 0}>{index + 1}</div>
            </div>
            <div class='top-title font-weight-bold mt-10' title={entry.title}>{entry.title}</div>
            <div class='text-muted font-size-13'>{plural(item.episodes, 'episode')} · {hoursValue(item.minutes)} h</div>
          </div>
        {/each}
      </div>
    </section>
  {/if}

  <section class='panel'>
    <div class='d-flex justify-content-between align-items-baseline flex-wrap'>
      <h2 class='panel-title'>Episodes per month</h2>
      {#if stats.months[bestMonth] > 0}
        <div class='text-muted font-size-14'>Busiest month: <span class='text-white font-weight-bold'>{MONTH_NAMES[bestMonth]}</span> ({plural(stats.months[bestMonth], 'episode')})</div>
      {/if}
    </div>
    <MonthChart months={stats.months} />
  </section>

  <div class='two-columns'>
    <section class='panel'>
      <h2 class='panel-title'>Top genres</h2>
      {#each stats.genres as genre (genre.name)}
        <div class='rank-row'>
          <div class='d-flex justify-content-between font-size-14'>
            <span class='font-weight-bold'>{genre.name}</span>
            <span class='text-muted'>{plural(genre.count, 'anime')}</span>
          </div>
          <div class='meter mt-5'><div class='meter-fill' style='width: {(genre.count / maxGenre) * 100}%'></div></div>
        </div>
      {:else}
        <div class='text-muted'>No genres yet.</div>
      {/each}
    </section>
    <section class='panel'>
      <h2 class='panel-title'>Top studios</h2>
      {#each stats.studios as studio, index (studio.name)}
        <div class='studio-row d-flex align-items-center'>
          <div class='studio-rank font-weight-very-bold'>{index + 1}</div>
          <div class='flex-grow-1 text-truncate font-weight-bold'>{studio.name}</div>
          <div class='text-muted font-size-13 ml-10 text-nowrap'>{plural(studio.count, 'anime')} · {plural(studio.episodes, 'ep')}</div>
        </div>
      {:else}
        <div class='text-muted'>No studios yet.</div>
      {/each}
    </section>
  </div>

  <div class='highlights'>
    {#if stats.bingeDay}
      <section class='panel highlight'>
        <div class='highlight-head'><Flame size='1.8rem' /> Biggest binge day</div>
        <div class='highlight-value'>{formatDay(stats.bingeDay.date)}</div>
        <div class='text-muted'>{plural(stats.bingeDay.episodes, 'episode')} · {hoursValue(stats.bingeDay.minutes)} hours</div>
        <div class='d-flex mt-10'>
          {#each stats.bingeDay.mediaIds.slice(0, 4) as id (id)}
            <SmartImage class='mini-cover mr-10' images={[lookup(review.media, id).cover, './404_cover.png']} title={lookup(review.media, id).title} />
          {/each}
        </div>
      </section>
    {/if}
    {#if stats.first}
      <section class='panel highlight d-flex'>
        <SmartImage class='side-cover mr-15' images={[lookup(review.media, stats.first.mediaId).cover, './404_cover.png']} title={lookup(review.media, stats.first.mediaId).title} />
        <div class='min-w-0'>
          <div class='highlight-head'><Play size='1.8rem' /> First anime of the year</div>
          <div class='highlight-value text-truncate-2'>{lookup(review.media, stats.first.mediaId).title}</div>
          <div class='text-muted'>{dateOf(stats.first.time)}</div>
        </div>
      </section>
    {/if}
    {#if stats.last}
      <section class='panel highlight d-flex'>
        <SmartImage class='side-cover mr-15' images={[lookup(review.media, stats.last.mediaId).cover, './404_cover.png']} title={lookup(review.media, stats.last.mediaId).title} />
        <div class='min-w-0'>
          <div class='highlight-head'><Flag size='1.8rem' /> Last anime of the year</div>
          <div class='highlight-value text-truncate-2'>{lookup(review.media, stats.last.mediaId).title}</div>
          <div class='text-muted'>{dateOf(stats.last.time)}</div>
        </div>
      </section>
    {/if}
    {#if stats.topRated}
      <section class='panel highlight d-flex'>
        <SmartImage class='side-cover mr-15' images={[lookup(review.media, stats.topRated.mediaId).cover, './404_cover.png']} title={lookup(review.media, stats.topRated.mediaId).title} />
        <div class='min-w-0'>
          <div class='highlight-head'><Star size='1.8rem' /> Highest rated</div>
          <div class='highlight-value text-truncate-2'>{lookup(review.media, stats.topRated.mediaId).title}</div>
          <div class='text-muted'>{stats.topRated.score} / 10</div>
        </div>
      </section>
    {/if}
  </div>
{/if}

{#if review.local?.hasData}
  <section class='panel'>
    <div class='d-flex justify-content-between align-items-baseline flex-wrap'>
      <h2 class='panel-title'><Tv size='2rem' class='mr-5' /> Shows &amp; movies</h2>
      <div class='text-muted font-size-14'>From this device's watch history (not on AniList)</div>
    </div>
    <div class='d-flex flex-wrap local-numbers'>
      <div><span class='local-value'>{formatNumber(review.local.titles)}</span> titles</div>
      <div><span class='local-value'>{formatNumber(review.local.episodes)}</span> episodes / movies finished</div>
      <div><span class='local-value'>{formatNumber(hoursValue(review.local.minutes))}</span> hours</div>
    </div>
    <div class='top-row d-flex mt-15'>
      {#each review.local.top as item (item.key)}
        <div class='top-item'>
          <div class='cover-wrap'>
            <SmartImage class='cover w-full h-full' images={[item.cover, './404_cover.png']} title={item.title} />
          </div>
          <div class='top-title font-weight-bold mt-10' title={item.title}>{item.title}</div>
          <div class='text-muted font-size-13'>{hoursValue(item.minutes)} h{item.episodes && !item.isMovie ? ` · ${plural(item.episodes, 'episode')}` : ''}</div>
        </div>
      {/each}
    </div>
  </section>
{/if}

{#if !localOnly}
  <p class='text-muted font-size-12 mt-20 mb-0'>
    Estimated from your AniList list activity: episode counts follow your progress updates, hours use each episode's length.
    Updated {updated}.
  </p>
{/if}

<style>
  .hero {
    border-radius: 2.4rem;
    background: rgba(255, 255, 255, 0.04);
    min-height: 26rem;
    display: flex;
    align-items: flex-end;
  }
  .hero-image {
    inset: 0;
    background-size: cover;
    background-position: center;
    opacity: 0.45;
    filter: blur(2px) saturate(1.2);
    transform: scale(1.03);
    mask-image: linear-gradient(180deg, rgba(0, 0, 0, 1) 30%, rgba(0, 0, 0, 0) 100%);
  }
  .hero-content {
    width: 100%;
    padding: 3.2rem;
    gap: 2rem;
  }
  .eyebrow {
    color: var(--accent-color);
    letter-spacing: 0.3em;
    font-size: 1.3rem;
  }
  h1 {
    font-size: clamp(3rem, 4.5vw, 5.2rem);
    line-height: 1.1;
  }
  .avatar {
    width: 3.2rem;
    height: 3.2rem;
    object-fit: cover;
  }
  .big-numbers {
    gap: 3.2rem;
  }
  .big-value {
    font-size: clamp(3.2rem, 4vw, 4.8rem);
    font-weight: 900;
    line-height: 1;
    color: var(--accent-color);
  }
  .big-label {
    margin-top: 0.4rem;
    font-size: 1.4rem;
    color: rgba(255, 255, 255, 0.65);
  }
  .grid-cards {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr));
    gap: 1.2rem;
    margin-top: 1.6rem;
  }
  .card-box, .panel {
    background: rgba(255, 255, 255, 0.05);
    border-radius: 1.8rem;
  }
  .card-box {
    padding: 1.8rem 2rem;
  }
  .card-value {
    font-size: 3rem;
    font-weight: 800;
    line-height: 1.1;
  }
  .card-unit {
    font-size: 1.6rem;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.6);
  }
  .card-label {
    margin-top: 0.4rem;
    color: rgba(255, 255, 255, 0.65);
    font-size: 1.4rem;
  }
  .panel {
    padding: 2.4rem;
    margin-top: 1.6rem;
  }
  .panel-title {
    font-size: 2rem;
    font-weight: 800;
    margin: 0 0 1.6rem;
    display: flex;
    align-items: center;
  }
  .top-row {
    gap: 1.6rem;
    overflow-x: auto;
    padding-bottom: 0.4rem;
  }
  .top-item {
    width: 15rem;
    flex: 0 0 15rem;
    min-width: 0;
  }
  .cover-wrap {
    width: 15rem;
    height: 21.5rem;
    border-radius: 1.2rem;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.06);
  }
  .cover-wrap :global(.cover) {
    object-fit: cover;
  }
  .rank {
    top: 0.8rem;
    left: 0.8rem;
    width: 3.4rem;
    height: 3.4rem;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(14, 15, 19, 0.85);
    font-size: 1.6rem;
  }
  .rank.first {
    background: var(--accent-color);
    color: #0e0f13;
  }
  .top-title {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-size: 1.4rem;
  }
  .two-columns {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(30rem, 1fr));
    gap: 0 1.6rem;
  }
  .rank-row + .rank-row {
    margin-top: 1.4rem;
  }
  .meter {
    height: 0.8rem;
    border-radius: 0.4rem;
    background: rgba(255, 255, 255, 0.08);
    overflow: hidden;
  }
  .meter-fill {
    height: 100%;
    border-radius: 0.4rem;
    background: var(--accent-color);
  }
  .studio-row {
    padding: 0.8rem 0;
    font-size: 1.5rem;
  }
  .studio-row + .studio-row {
    border-top: 1px solid rgba(255, 255, 255, 0.06);
  }
  .studio-rank {
    width: 3rem;
    color: var(--accent-color);
  }
  .highlights {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(30rem, 1fr));
    gap: 0 1.6rem;
  }
  .highlight-head {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    color: var(--accent-color);
    font-weight: 700;
    font-size: 1.4rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }
  .highlight-value {
    font-size: 2.2rem;
    font-weight: 800;
    margin: 0.6rem 0 0.2rem;
  }
  .text-truncate-2 {
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .min-w-0 {
    min-width: 0;
  }
  .highlight :global(.mini-cover) {
    width: 5.6rem;
    height: 8rem;
    object-fit: cover;
    border-radius: 0.8rem;
  }
  .highlight :global(.side-cover) {
    width: 8.4rem;
    height: 12rem;
    flex: 0 0 8.4rem;
    object-fit: cover;
    border-radius: 1rem;
  }
  .local-numbers {
    gap: 2.4rem;
    color: rgba(255, 255, 255, 0.65);
    font-size: 1.5rem;
  }
  .local-value {
    font-size: 2.6rem;
    font-weight: 800;
    color: var(--accent-color);
    margin-right: 0.4rem;
  }
</style>
