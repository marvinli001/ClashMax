import type { SiteContent } from '@/lib/content'
import { ActionRow } from './ActionRow'
import { RoutingChart } from './RoutingChart'
import styles from './Hero.module.css'

export function Hero({ content }: { content: SiteContent }) {
  return (
    <section className={styles.hero}>
      <div className={`frame ${styles.grid}`}>
        <div>
          <h1 className={styles.title}>
            {content.hero.headline}
            <span className={styles.tail}>{content.hero.headlineTail}</span>
          </h1>
          <p className={styles.sub}>{content.hero.subtext}</p>
          <div className={styles.actions}>
            <ActionRow content={content} />
          </div>
        </div>
        <RoutingChart content={content} />
      </div>
    </section>
  )
}
