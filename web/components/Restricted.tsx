import type { SiteContent } from '@/lib/content'
import { Band } from './Band'
import styles from './Restricted.module.css'

export function Restricted({ content }: { content: SiteContent }) {
  const { restricted } = content
  return (
    <Band id="boundaries" heading={restricted.heading} body={restricted.body}>
      <div className={styles.hatch} aria-hidden="true" />
      <ul className={styles.list}>
        {restricted.boundaries.map((boundary) => (
          <li className={styles.item} key={boundary.title}>
            <h3 className={styles.title}>{boundary.title}</h3>
            <p className={styles.detail}>{boundary.detail}</p>
          </li>
        ))}
      </ul>
    </Band>
  )
}
