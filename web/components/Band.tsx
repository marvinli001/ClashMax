import type { ReactNode } from 'react'
import styles from './Band.module.css'

/**
 * Every section below the fold reads the same way: the heading on the left, the
 * one paragraph that qualifies it on the right, ruled off from what came
 * before. No label sits above the heading — the heading is the label.
 */
export function Band({
  id,
  heading,
  body,
  children,
}: {
  id: string
  heading: string
  body: string
  children?: ReactNode
}) {
  const headingId = `${id}-heading`
  return (
    <section id={id} className="band" aria-labelledby={headingId}>
      <div className="frame">
        <div className={styles.head}>
          <h2 id={headingId} className={styles.heading}>
            {heading}
          </h2>
          <p className={`prose ${styles.body}`}>{body}</p>
        </div>
        {children}
      </div>
    </section>
  )
}
