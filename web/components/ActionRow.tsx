'use client'

import type { SiteContent } from '@/lib/content'
import { LINKS } from '@/lib/site'
import { useRelease } from './ReleaseProvider'
import { MarkDownload, MarkReport, MarkSource } from './Symbology'
import styles from './ActionRow.module.css'

/**
 * The action row the incumbent page earned its keep with, rebuilt on the
 * chart's own shape rule: controls are the only pill on the page.
 * The primary link points at the real DMG asset once GitHub answers, and at
 * the release page until then, so it is never dead.
 */
export function ActionRow({ content }: { content: SiteContent }) {
  const release = useRelease()

  return (
    <div className={styles.row}>
      <a
        className="pill pill--primary"
        href={release.appDownloadURL}
        aria-label={content.hero.primaryCtaAria}
      >
        <MarkDownload size={18} />
        {content.hero.primaryCta}
      </a>
      <a className="pill" href={LINKS.repo}>
        <MarkSource size={18} />
        {content.hero.secondaryCta}
      </a>
      <a className="pill" href={LINKS.newIssue}>
        <MarkReport size={18} />
        {content.hero.tertiaryCta}
      </a>
    </div>
  )
}
