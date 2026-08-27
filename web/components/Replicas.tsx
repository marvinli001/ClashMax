'use client'

import { useId, useRef, useState } from 'react'
import type { Clearance, SiteContent } from '@/lib/content'
import { Band } from './Band'
import styles from './Replicas.module.css'

const chainTone: Record<Clearance, string> = {
  proxy: styles.chainProxy,
  direct: styles.chainDirect,
  reject: styles.chainReject,
}

function delayTone(ms: number): string {
  if (ms < 100) return styles.fast
  if (ms < 250) return styles.mid
  return styles.slow
}

function ProxiesReplica({ content }: { content: SiteContent }) {
  const { proxies } = content.replicas
  return (
    <div className={styles.windowList}>
      <div className={styles.groupHead}>
        <span className={styles.groupName}>{proxies.groupName}</span>
        <span className={styles.badge}>{proxies.groupType}</span>
        <span className={styles.groupAction}>{proxies.testAll}</span>
      </div>
      <ul className={styles.nodes}>
        {proxies.nodes.map((node) => (
          <li
            className={`${styles.node} ${node.current ? styles.nodeCurrent : ''}`}
            key={node.name}
          >
            <span className={styles.check} aria-hidden="true">
              {node.current ? (
                <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                  <path
                    d="M2.5 7.5 5.5 10.5 11.5 3.5"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              ) : null}
            </span>
            <span className={styles.nodeName}>{node.name}</span>
            {node.delay === null ? (
              <span className={styles.delay}>
                <span className={`${styles.dot} ${styles.dotEmpty}`} />
                &mdash;
              </span>
            ) : (
              <span className={`${styles.delay} ${delayTone(node.delay)}`}>
                <span className={styles.dot} />
                {node.delay} ms
              </span>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}

function ConnectionsReplica({ content }: { content: SiteContent }) {
  const { connections } = content.replicas
  return (
    <div className={styles.windowTable}>
      <table className={styles.table}>
        <thead>
          <tr>
            <th scope="col">{connections.columns.host}</th>
            <th scope="col">{connections.columns.rule}</th>
            <th scope="col">{connections.columns.chain}</th>
            <th scope="col" className={styles.numeric}>
              {connections.columns.upload}
            </th>
          </tr>
        </thead>
        <tbody>
          {connections.rows.map((row) => (
            <tr key={row.host}>
              <td>{row.host}</td>
              <td className={styles.ruleCell}>{row.rule}</td>
              <td>
                <span className={`${styles.chain} ${chainTone[row.clearance]}`}>{row.chain}</span>
              </td>
              <td className={styles.numeric}>{row.up}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className={styles.totals}>{connections.totals}</p>
    </div>
  )
}

/**
 * Two more app surfaces, rebuilt in HTML rather than screenshotted so they stay
 * sharp and selectable at any size. Inside the mat the markup speaks macOS,
 * because that is what it is reproducing; the chart only frames and captions
 * it, the same way it frames the photograph in FIG. 1.
 */
export function Replicas({ content }: { content: SiteContent }) {
  const { replicas } = content
  const [active, setActive] = useState<'proxies' | 'connections'>('proxies')
  const base = useId()
  const refs = useRef<Record<string, HTMLButtonElement | null>>({})
  const figure = replicas.figures[active]

  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const order = replicas.tabs.map((tab) => tab.id)
    const index = order.indexOf(active)
    let next = index
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (index + 1) % order.length
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp')
      next = (index - 1 + order.length) % order.length
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = order.length - 1
    else return
    event.preventDefault()
    setActive(order[next])
    refs.current[order[next]]?.focus()
  }

  return (
    <Band id="replicas" heading={replicas.heading} body={replicas.body}>
      <div className={styles.tabs} role="tablist" onKeyDown={onKeyDown}>
        {replicas.tabs.map((tab) => (
          <button
            type="button"
            key={tab.id}
            id={`${base}-${tab.id}-tab`}
            className={styles.tab}
            role="tab"
            aria-selected={active === tab.id}
            aria-controls={`${base}-${tab.id}-panel`}
            tabIndex={active === tab.id ? 0 : -1}
            ref={(node) => {
              refs.current[tab.id] = node
            }}
            onClick={() => setActive(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>

      <figure
        className={`plate plate--ticked ${styles.plate}`}
        id={`${base}-${active}-panel`}
        role="tabpanel"
        aria-labelledby={`${base}-${active}-tab`}
        tabIndex={0}
      >
        <div className={`appmat ${styles.mat}`}>
          {active === 'proxies' ? (
            <ProxiesReplica content={content} />
          ) : (
            <ConnectionsReplica content={content} />
          )}
        </div>
        <figcaption className={styles.caption}>
          <span className="chartLabel">{figure.figure}</span>
          {figure.caption}
        </figcaption>
      </figure>
    </Band>
  )
}
