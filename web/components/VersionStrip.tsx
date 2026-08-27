'use client'

import type { ReactNode } from 'react'
import type { SiteContent } from '@/lib/content'
import { formatReleaseDate } from '@/lib/release'
import { useRelease } from './ReleaseProvider'
import styles from './VersionStrip.module.css'

/**
 * The live version strip, kept from the incumbent page and re-cut as an
 * instrument band: four readings ruled apart, plus one honest state light
 * saying whether GitHub answered or the committed values are on screen.
 *
 * The light sits in the first cell's label slot, over the reading it actually
 * qualifies - the same place the incumbent page put it. Parked in the last
 * cell it read as a footnote to `macOS 15+`, which it never described.
 */
export function VersionStrip({ content }: { content: SiteContent }) {
  const release = useRelease()
  const { strip } = content
  const live = release.appSource === 'live' && release.mihomoSource === 'live'

  const reading = (value: string, source: string) => (
    <span key={value} className={`${styles.value} ${source === 'live' ? styles.settle : ''}`} data-num>
      {value}
    </span>
  )

  const cell = (label: ReactNode, value: ReactNode, meta: ReactNode) => (
    <div className={styles.cell}>
      {typeof label === 'string' ? <span className="chartLabel">{label}</span> : label}
      {value}
      <span className={styles.meta}>{meta}</span>
    </div>
  )

  return (
    <section className={styles.strip} aria-label={`${content.meta.siteName} ${strip.appVersion}`}>
      <div className="frame">
        <div className={styles.inner}>
          {cell(
            <span className={styles.state} data-state={live ? 'live' : 'fallback'}>
              {live ? strip.live : strip.fallback}
            </span>,
            reading(release.appVersion, release.appSource),
            <>
              {strip.released} {formatReleaseDate(release.appPublishedAt, content.intlLocale)} ·{' '}
              <a href={release.appReleaseURL}>{strip.releaseNotes}</a>
            </>,
          )}
          {cell(strip.appBuild, reading(release.appBuild, release.appSource), strip.buildNote)}
          {cell(
            strip.core,
            reading(release.mihomoVersion, release.mihomoSource),
            <>
              {strip.coreReleased} {formatReleaseDate(release.mihomoPublishedAt, content.intlLocale)}
            </>,
          )}
          {cell(
            strip.platform,
            <span className={styles.value}>{strip.platformValue}</span>,
            strip.platformNote,
          )}
        </div>
      </div>
    </section>
  )
}
