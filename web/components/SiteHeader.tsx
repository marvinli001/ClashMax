import Image from 'next/image'
import type { SiteContent } from '@/lib/content'
import { LINKS, asset, localePath } from '@/lib/site'
import { LanguageToggle } from './LanguageToggle'
import styles from './SiteHeader.module.css'

export function SiteHeader({ content }: { content: SiteContent }) {
  return (
    <header className={styles.header}>
      <div className={`frame ${styles.inner}`}>
        <a className={styles.brand} href={localePath(content.locale)}>
          <Image
            className={styles.icon}
            src={asset('/clashmax-icon.png')}
            alt=""
            width={24}
            height={24}
            priority
          />
          ClashMax
        </a>
        <nav className={styles.links} aria-label={content.meta.siteName}>
          <a className={styles.link} href={LINKS.repo}>
            {content.nav.repo}
          </a>
          <LanguageToggle
            current={content.locale}
            label={content.nav.languageLabel}
            otherName={content.otherLocaleName}
          />
        </nav>
      </div>
    </header>
  )
}
