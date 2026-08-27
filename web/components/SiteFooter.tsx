import type { SiteContent } from '@/lib/content'
import { LINKS, localePath } from '@/lib/site'
import { MarkRose } from './Symbology'
import styles from './SiteFooter.module.css'

export function SiteFooter({ content }: { content: SiteContent }) {
  const { footer } = content
  const other = content.locale === 'en' ? 'zh' : 'en'

  return (
    <footer className={styles.footer}>
      <div className="frame">
        <div className={styles.grid}>
          <div className={styles.identity}>
            <MarkRose className={styles.rose} />
            {/* The note belongs to the wordmark beside it, so it says what
                ClashMax is - the core it drives is named in the link list. */}
            <div className={styles.identityText}>
              <span className={styles.name}>{content.meta.siteName}</span>
              <p className={styles.note}>{footer.note}</p>
            </div>
          </div>
          <ul className={styles.links}>
            <li>
              <a href={LINKS.repo}>{footer.source}</a>
            </li>
            <li>
              <a href={LINKS.issues}>{footer.issues}</a>
            </li>
            <li>
              <a href={LINKS.discussions}>{footer.discussions}</a>
            </li>
            <li>
              <a href={LINKS.security}>{footer.security}</a>
            </li>
            <li>
              <a href={LINKS.mihomo}>{footer.core}</a>
            </li>
          </ul>
        </div>
        <div className={styles.rule}>
          <span>
            <a href={LINKS.license}>{footer.licenseLink}</a> · {footer.license}
          </span>
          <span className={styles.spacer}>
            <a href={localePath(other)} hrefLang={other === 'en' ? 'en' : 'zh-Hans'} lang={other === 'en' ? 'en' : 'zh-Hans'}>
              {footer.otherLocale}
            </a>
          </span>
        </div>
      </div>
    </footer>
  )
}
