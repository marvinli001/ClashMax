import type { SiteContent } from '@/lib/content'
import { Band } from './Band'
import styles from './ConfigPlate.module.css'

/** The transfer between the two files, drawn the same way the chart draws a
 *  route: one hairline and one arrowhead, no box-and-shadow diagram. */
function Transfer() {
  return (
    <svg
      className={styles.link}
      width="64"
      height="16"
      viewBox="0 0 64 16"
      fill="none"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M0 8h56" stroke="currentColor" strokeWidth="1.25" />
      <polygon points="54,3 54,13 63,8" fill="currentColor" />
    </svg>
  )
}

export function ConfigPlate({ content }: { content: SiteContent }) {
  const { config } = content
  return (
    <Band id="config" heading={config.heading} body={config.body}>
      <div className={`plate plate--graticule plate--ticked ${styles.plate}`}>
        <div className={styles.flow}>
          <div className={styles.panel}>
            <span className={styles.panelName}>{config.sourceLabel}</span>
            <p className={styles.panelNote}>{config.sourceNote}</p>
          </div>
          <Transfer />
          <div className={styles.panel}>
            <span className={styles.panelName}>{config.runtimeLabel}</span>
            <p className={styles.panelNote}>{config.runtimeNote}</p>
          </div>
        </div>

        <div className={styles.keys}>
          <div className={styles.keysHead}>
            <span className="chartLabel">{config.injected}</span>
          </div>
          <dl className={styles.keyList}>
            {config.injectedKeys.map((entry) => (
              <div className={styles.keyRow} key={entry.key}>
                <dt className={styles.key}>{entry.key}</dt>
                <dd className={styles.val}>
                  <span className={styles.leader} aria-hidden="true" />
                  <span>{entry.value}</span>
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </div>
    </Band>
  )
}
