import type { SiteContent } from '@/lib/content'
import { SURFACE_MARKS } from './Symbology'
import { Band } from './Band'
import styles from './Legend.module.css'

export function Legend({ content }: { content: SiteContent }) {
  const { legend } = content
  return (
    <Band id="surfaces" heading={legend.heading} body={legend.body}>
      <ul className={styles.list}>
        {legend.entries.map((entry) => {
          const Symbol = SURFACE_MARKS[entry.symbol]
          return (
            <li className={styles.row} key={entry.symbol}>
              <Symbol className={styles.mark} size={18} />
              <div>
                <p className={styles.name}>{entry.name}</p>
                <p className={styles.detail}>{entry.detail}</p>
              </div>
            </li>
          )
        })}
      </ul>
    </Band>
  )
}
