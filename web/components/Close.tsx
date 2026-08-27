'use client'

import type { SiteContent } from '@/lib/content'
import { LINKS } from '@/lib/site'
import { useRelease } from './ReleaseProvider'
import { MarkDownload } from './Symbology'
import styles from './Close.module.css'

export function Close({ content }: { content: SiteContent }) {
  const release = useRelease()
  const { close } = content

  return (
    <section className={styles.band} aria-labelledby="close-heading">
      <div className="frame">
        <div className={`plate plate--graticule plate--ticked ${styles.plate}`}>
          <div className={`knockout-host ${styles.text}`}>
            <h2 id="close-heading" className={styles.heading}>
              <span className="knockout">{close.heading}</span>
            </h2>
            <p className={styles.body}>
              <span className="knockout">{close.body}</span>
            </p>
          </div>
          <div className={styles.actions}>
            <a
              className="pill pill--primary"
              href={release.appDownloadURL}
              aria-label={content.hero.primaryCtaAria}
            >
              <MarkDownload size={18} />
              {close.cta}
            </a>
            <a className={styles.alt} href={LINKS.issues}>
              {close.alt}
            </a>
          </div>
        </div>
      </div>
    </section>
  )
}
