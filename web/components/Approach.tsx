import type { SiteContent } from '@/lib/content'
import { Band } from './Band'
import styles from './Approach.module.css'

export function Approach({ content }: { content: SiteContent }) {
  const { approach } = content
  return (
    <Band id="install" heading={approach.heading} body={approach.body}>
      <ol className={styles.steps}>
        {approach.steps.map((step) => (
          <li className={styles.step} key={step.title}>
            <h3 className={styles.title}>{step.title}</h3>
            <p className={styles.detail}>{step.detail}</p>
          </li>
        ))}
      </ol>
    </Band>
  )
}
