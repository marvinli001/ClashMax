import type { ReactNode } from 'react'
import type { MetricMark, Readout, SiteContent } from '@/lib/content'
import { Band } from './Band'
import styles from './DashboardFigure.module.css'

/**
 * FIG. 1: the Dashboard, redrawn.
 *
 * Drawn in HTML for the same reasons FIG. 2 and FIG. 3 are. A screenshot of a
 * running console is stale the day it is taken, soft at every size that is not
 * its own, and unreadable to anything but an eye - and a screenshot of a
 * stopped app cannot honestly caption itself as running. Every label and
 * readout below is the app's own. Inside the mat the markup speaks macOS,
 * because that is what it reproduces; the chart only frames and captions it.
 */

/**
 * macOS glyphs. Round caps and joins on a 16-unit grid, deliberately unlike
 * the chart's square-capped symbology: the mat is a different world.
 */
function Glyph({ children, size = 14 }: { children: ReactNode; size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.4}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  )
}

const GlyphShield = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <path d="M8 1.6 13.2 3.4v4.1c0 3.1-2.1 5.4-5.2 6.9-3.1-1.5-5.2-3.8-5.2-6.9V3.4L8 1.6Z" />
    <path d="M8 1.6v12.8" />
  </Glyph>
)

const GlyphStop = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <rect x="4" y="4" width="8" height="8" rx="1.2" fill="currentColor" stroke="none" />
  </Glyph>
)

const GlyphDown = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <path d="M8 2.6v10.8" />
    <path d="M3.6 9 8 13.4 12.4 9" />
  </Glyph>
)

const GlyphUp = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <path d="M8 13.4V2.6" />
    <path d="M3.6 7 8 2.6 12.4 7" />
  </Glyph>
)

const GlyphNetwork = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <circle cx="8" cy="8" r="5.9" />
    <path d="M2.1 8h11.8" />
    <path d="M8 2.1c1.6 1.7 2.4 3.7 2.4 5.9S9.6 12.2 8 13.9C6.4 12.2 5.6 10.2 5.6 8s.8-4.2 2.4-5.9Z" />
  </Glyph>
)

const GlyphRules = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <path d="M6 4h7.6M6 8h7.6M6 12h7.6" />
    <path d="M2.6 4h.8M2.6 8h.8M2.6 12h.8" />
  </Glyph>
)

const GlyphLocation = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <circle cx="8" cy="8" r="6" />
    <circle cx="8" cy="8" r="1.9" />
  </Glyph>
)

const GlyphChevron = ({ size }: { size?: number }) => (
  <Glyph size={size}>
    <path d="M4.5 6.4 8 9.9l3.5-3.5" />
  </Glyph>
)

const METRIC_MARKS: Record<MetricMark, () => ReactNode> = {
  down: () => <GlyphDown />,
  up: () => <GlyphUp />,
  network: () => <GlyphNetwork />,
  rules: () => <GlyphRules />,
}

const METRIC_TONES: Record<MetricMark, string> = {
  down: styles.toneCyan,
  up: styles.toneIndigo,
  network: styles.toneOrange,
  rules: styles.toneGreen,
}

function Pill({ label, value, tone }: Readout & { tone?: string }) {
  return (
    <span className={`${styles.pill} ${tone ?? ''}`}>
      <span className={styles.pillLabel}>{label}</span>
      <span className={styles.pillValue}>{value}</span>
    </span>
  )
}

export function DashboardFigure({ content }: { content: SiteContent }) {
  const { dashboard } = content
  const { app } = dashboard
  const { node, network } = app

  return (
    <Band id="console" heading={dashboard.heading} body={dashboard.body}>
      <figure className={`plate plate--ticked ${styles.plate}`}>
        <div className={`appmat ${styles.mat}`}>
          <div className={styles.stack}>
            <section className={styles.card}>
              <div className={styles.head}>
                <span className={styles.core}>
                  <GlyphShield size={28} />
                </span>
                <div className={styles.headMain}>
                  <p className={styles.status}>
                    <GlyphShield size={17} />
                    {app.status}
                  </p>
                  <div className={styles.pills}>
                    {app.pills.map((pill) => (
                      <Pill key={pill.label} {...pill} />
                    ))}
                  </div>
                </div>
                <div className={styles.run}>
                  <span className={styles.stop}>
                    <GlyphStop size={12} />
                    {app.stop}
                  </span>
                  <Pill {...app.proxy} tone={styles.pillLive} />
                </div>
              </div>

              <div className={styles.inset}>
                {app.info.map((item) => (
                  <span className={styles.infoItem} key={item.label}>
                    <span className={styles.infoLabel}>{item.label}</span>
                    <span className={styles.infoValue}>{item.value}</span>
                  </span>
                ))}
              </div>
            </section>

            <div className={styles.tiles}>
              {app.metrics.map((metric) => (
                <div className={`${styles.card} ${styles.tile}`} key={metric.label}>
                  <span className={`${styles.tileMark} ${METRIC_TONES[metric.mark]}`}>
                    {METRIC_MARKS[metric.mark]()}
                  </span>
                  <span className={styles.tileLabel}>{metric.label}</span>
                  <span className={styles.tileValue}>{metric.value}</span>
                  <span className={styles.tileFoot}>{metric.foot}</span>
                </div>
              ))}
            </div>

            <div className={styles.pair}>
              <section className={styles.card}>
                <p className={styles.cardHead}>
                  <span className={styles.cardHeadMark}>
                    <GlyphLocation size={15} />
                  </span>
                  {node.title}
                  <span className={styles.cardBadge}>{node.badge}</span>
                </p>

                <div className={styles.node}>
                  <span className={styles.nodeMark}>
                    <GlyphShield size={19} />
                  </span>
                  <span className={styles.nodeText}>
                    <span className={styles.nodeName}>{node.name}</span>
                    <span className={styles.nodeMeta}>
                      <span>{node.group}</span>
                      <span className={styles.nodeType}>{node.type}</span>
                    </span>
                  </span>
                  <span className={styles.nodeDelay}>{node.delay}</span>
                </div>

                <div className={styles.pickers}>
                  <span className={styles.picker}>
                    <span className={styles.pickerLabel}>{node.groupLabel}</span>
                    <span className={styles.pickerValue}>
                      {node.group}
                      <GlyphChevron size={12} />
                    </span>
                  </span>
                  <span className={`${styles.picker} ${styles.pickerWide}`}>
                    <span className={styles.pickerLabel}>{node.nodeLabel}</span>
                    <span className={styles.pickerValue}>
                      {node.name}
                      <GlyphChevron size={12} />
                    </span>
                  </span>
                </div>
              </section>

              <section className={styles.card}>
                <p className={styles.cardHead}>
                  <span className={styles.cardHeadMark}>
                    <GlyphNetwork size={15} />
                  </span>
                  {network.title}
                </p>

                <div className={styles.stats}>
                  {network.stats.map((stat) => (
                    <span className={styles.stat} key={stat.label}>
                      <span className={styles.statLabel}>{stat.label}</span>
                      <span className={styles.statValue}>{stat.value}</span>
                    </span>
                  ))}
                </div>

                <div className={styles.lines}>
                  {network.lines.map((line) => (
                    <p className={styles.line} key={line.label}>
                      <span className={styles.lineLabel}>{line.label}</span>
                      <span className={styles.lineValue}>{line.value}</span>
                    </p>
                  ))}
                </div>
              </section>
            </div>
          </div>
        </div>

        <div className={styles.callouts}>
          {dashboard.callouts.map((callout) => (
            <div className={styles.callout} key={callout.label}>
              <span className="chartLabel">{callout.label}</span>
              <span className={styles.calloutDetail}>{callout.detail}</span>
            </div>
          ))}
        </div>

        <figcaption className={styles.caption}>
          <span className="chartLabel">{dashboard.figure}</span>
          {dashboard.caption}
        </figcaption>
      </figure>
    </Band>
  )
}
