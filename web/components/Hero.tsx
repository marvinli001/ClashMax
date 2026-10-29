import type { SiteContent } from '@/lib/content'
import { asset } from '@/lib/site'
import { ActionRow } from './ActionRow'
import styles from './Hero.module.css'

/** Captured from the app at 1180 x 812 by the snapshot harness, light and dark. */
const SHOT_WIDTH = 1180
const SHOT_HEIGHT = 812

export function Hero({ content }: { content: SiteContent }) {
  const shot = (variant: string) => asset(`/app-home-${content.locale}${variant}.png`)

  return (
    <section className={styles.hero}>
      <div className={`frame ${styles.grid}`}>
        <h1 className={styles.title}>
          {content.hero.headline}
          <span className={styles.tail}>{content.hero.headlineTail}</span>
        </h1>
        <div className={styles.lede}>
          <p className={styles.sub}>{content.hero.subtext}</p>
          <div className={styles.actions}>
            <ActionRow content={content} />
          </div>
        </div>
        {/* A real capture of the shipping app, not a redraw: the first thing a
            visitor sees is the console they will actually get. It spans the
            frame because a dense console is unreadable at half width. */}
        <figure className={`plate plate--ticked ${styles.shot}`}>
          <picture>
            <source srcSet={shot('-dark')} media="(prefers-color-scheme: dark)" />
            <img
              className={styles.image}
              src={shot('')}
              alt={content.shot.alt}
              width={SHOT_WIDTH}
              height={SHOT_HEIGHT}
              fetchPriority="high"
              decoding="async"
            />
          </picture>
          <figcaption className={styles.caption}>{content.shot.caption}</figcaption>
        </figure>
      </div>
    </section>
  )
}
