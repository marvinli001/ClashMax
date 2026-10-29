import type { SiteContent } from '@/lib/content'
import { Band } from './Band'
import styles from './Faq.module.css'

/**
 * The questions are printed in full, never folded behind a disclosure: the
 * same text is what the FAQPage record and llms.txt hand to search and answer
 * engines, and an answer only a click reveals is one a visitor may never read.
 */
export function Faq({ content }: { content: SiteContent }) {
  const { faq } = content
  return (
    <Band id="faq" heading={faq.heading} body={faq.body}>
      <ul className={styles.list}>
        {faq.items.map((item) => (
          <li className={styles.item} key={item.question}>
            <h3 className={styles.question}>{item.question}</h3>
            <p className={styles.answer}>{item.answer}</p>
          </li>
        ))}
      </ul>
    </Band>
  )
}
