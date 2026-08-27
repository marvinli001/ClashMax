'use client'

import { type CSSProperties, useId, useState } from 'react'
import type { Clearance, SiteContent } from '@/lib/content'
import styles from './RoutingChart.module.css'

/**
 * The routing chart.
 *
 * The product's actual mechanism, operated rather than described: a request
 * leaves 127.0.0.1, runs the rule set in order, and is decided by the first
 * rule that matches it.
 *
 * The three clearances are the three edges of the chart, which is why nothing
 * ever re-crosses a boundary it has already passed. PROXY climbs out of the
 * corridor, REJECT descends, and DIRECT simply keeps going: the geometry says
 * what the words say.
 */

interface Geometry {
  /** viewBox */
  w: number
  h: number
  /** Origin of every route. */
  ox: number
  oy: number
  /** Position of boundary i along the corridor. */
  boundary: (i: number) => number
  /** Where the corridor ends when nothing turns it aside. */
  exit: number
  /** Where a turned route leaves the sheet. */
  proxyExit: number
  rejectExit: number
  /** Extent of a boundary line across the corridor. */
  spanStart: number
  spanEnd: number
  /** Inner edges of the two clearance bands. */
  proxyEdge: number
  rejectEdge: number
  vertical: boolean
}

const LANDSCAPE: Geometry = {
  w: 600,
  h: 400,
  ox: 46,
  oy: 200,
  boundary: (i) => 132 + i * 82,
  exit: 566,
  proxyExit: 44,
  rejectExit: 356,
  spanStart: 70,
  spanEnd: 330,
  proxyEdge: 70,
  rejectEdge: 330,
  vertical: false,
}

const PORTRAIT: Geometry = {
  w: 340,
  h: 486,
  ox: 152,
  oy: 52,
  boundary: (i) => 116 + i * 68,
  exit: 452,
  proxyExit: 24,
  rejectExit: 316,
  spanStart: 44,
  spanEnd: 296,
  proxyEdge: 44,
  rejectEdge: 296,
  vertical: true,
}

/** Point on the sheet, given corridor-space coordinates. */
function pt(g: Geometry, along: number, across: number): [number, number] {
  return g.vertical ? [across, along] : [along, across]
}

function routePath(g: Geometry, ruleIndex: number, clearance: Clearance): string {
  const b = g.boundary(ruleIndex)
  const [sx, sy] = pt(g, g.vertical ? g.oy : g.ox, g.vertical ? g.ox : g.oy)
  if (clearance === 'direct') {
    const [ex, ey] = pt(g, g.exit, g.vertical ? g.ox : g.oy)
    return `M ${sx} ${sy} L ${ex} ${ey}`
  }
  const across = clearance === 'proxy' ? g.proxyExit : g.rejectExit
  const [tx, ty] = pt(g, b, g.vertical ? g.ox : g.oy)
  const [ex, ey] = pt(g, b, across)
  return `M ${sx} ${sy} L ${tx} ${ty} L ${ex} ${ey}`
}

/**
 * Length of that polyline, in user units.
 *
 * Every segment a route can contain is axis-aligned, so the length is just the
 * sum of the leg extents - no DOM measurement, and the same number on the
 * server and in the browser. It drives the draw-on dash; see the note on
 * `.route` for why pathLength normalisation is not used.
 */
function routeLength(g: Geometry, ruleIndex: number, clearance: Clearance): number {
  const along = g.vertical ? g.oy : g.ox
  const across = g.vertical ? g.ox : g.oy
  if (clearance === 'direct') return Math.abs(g.exit - along)
  const exit = clearance === 'proxy' ? g.proxyExit : g.rejectExit
  return Math.abs(g.boundary(ruleIndex) - along) + Math.abs(exit - across)
}

/** Arrowhead at the end of the route, pointing the way the route left. */
function head(g: Geometry, ruleIndex: number, clearance: Clearance): string {
  const s = 5
  if (clearance === 'direct') {
    const [x, y] = pt(g, g.exit, g.vertical ? g.ox : g.oy)
    return g.vertical
      ? `${x - s},${y - s * 1.6} ${x + s},${y - s * 1.6} ${x},${y}`
      : `${x - s * 1.6},${y - s} ${x - s * 1.6},${y + s} ${x},${y}`
  }
  const across = clearance === 'proxy' ? g.proxyExit : g.rejectExit
  const dir = clearance === 'proxy' ? -1 : 1
  const [x, y] = pt(g, g.boundary(ruleIndex), across)
  return g.vertical
    ? `${x - dir * s * 1.6},${y - s} ${x - dir * s * 1.6},${y + s} ${x},${y}`
    : `${x - s},${y - dir * s * 1.6} ${x + s},${y - dir * s * 1.6} ${x},${y}`
}

const routeTone: Record<Clearance, string> = {
  proxy: styles.routeProxy,
  direct: styles.routeDirect,
  reject: styles.routeReject,
}
const headTone: Record<Clearance, string> = {
  proxy: styles.headProxy,
  direct: styles.headDirect,
  reject: styles.headReject,
}
const crossTone: Record<Clearance, string> = {
  proxy: styles.crossingProxy,
  direct: styles.crossingDirect,
  reject: styles.crossingReject,
}
const clearanceTone: Record<Clearance, string> = {
  proxy: 'clr-proxy',
  direct: 'clr-direct',
  reject: 'clr-reject',
}

function Sheet({
  g,
  content,
  ruleIndex,
  clearance,
  portrait,
}: {
  g: Geometry
  content: SiteContent
  ruleIndex: number
  clearance: Clearance
  portrait: boolean
}) {
  const { ruleSet, clearanceNames, origin } = content.plate
  const labelClass = `${styles.label} ${portrait ? styles.labelPortrait : ''}`
  const [oxp, oyp] = pt(g, g.vertical ? g.oy : g.ox, g.vertical ? g.ox : g.oy)

  // The corridor, from the origin to the far edge.
  const corridor = g.vertical
    ? `M ${g.ox} ${g.oy} L ${g.ox} ${g.exit}`
    : `M ${g.ox} ${g.oy} L ${g.exit} ${g.oy}`

  return (
    <svg
      className={`${styles.svg} ${portrait ? styles.portrait : styles.landscape}`}
      viewBox={`0 0 ${g.w} ${g.h}`}
      role="img"
      aria-label={content.plate.label}
    >
      {/* Clearance bands: PROXY above the corridor, REJECT below it. */}
      <rect
        className={styles.bandFill}
        x={0}
        y={0}
        width={g.vertical ? g.proxyEdge : g.w}
        height={g.vertical ? g.h : g.proxyEdge}
      />
      <rect
        className={styles.bandFillReject}
        x={g.vertical ? g.rejectEdge : 0}
        y={g.vertical ? 0 : g.rejectEdge}
        width={g.vertical ? g.w - g.rejectEdge : g.w}
        height={g.vertical ? g.h : g.h - g.rejectEdge}
      />
      <path
        className={styles.bandEdge}
        d={
          g.vertical
            ? `M ${g.proxyEdge} 0 L ${g.proxyEdge} ${g.h}`
            : `M 0 ${g.proxyEdge} L ${g.w} ${g.proxyEdge}`
        }
      />
      <path
        className={styles.bandEdgeReject}
        d={
          g.vertical
            ? `M ${g.rejectEdge} 0 L ${g.rejectEdge} ${g.h}`
            : `M 0 ${g.rejectEdge} L ${g.w} ${g.rejectEdge}`
        }
      />

      {/* Band lettering. */}
      <text
        className={`${styles.bandLabel} ${styles.bandLabelProxy}`}
        x={portrait ? 8 : 18}
        y={portrait ? 20 : 30}
      >
        {clearanceNames.proxy}
      </text>
      <text
        className={`${styles.bandLabel} ${styles.bandLabelReject}`}
        x={portrait ? g.w - 8 : 18}
        y={portrait ? 20 : g.h - 12}
        textAnchor={portrait ? 'end' : 'start'}
      >
        {clearanceNames.reject}
      </text>
      <text
        className={`${styles.bandLabel} ${styles.bandLabelDirect}`}
        x={portrait ? g.ox : g.exit}
        y={portrait ? g.h - 8 : g.oy - 14}
        textAnchor={portrait ? 'middle' : 'end'}
      >
        {clearanceNames.direct}
      </text>

      {/* The evaluation corridor. */}
      <path className={styles.corridor} d={corridor} />

      {/* Rule boundaries, in evaluation order. */}
      {ruleSet.map((rule, i) => {
        const b = g.boundary(i)
        const matched = i === ruleIndex
        const [x1, y1] = pt(g, b, g.spanStart)
        const [x2, y2] = pt(g, b, g.spanEnd)
        const [lx, ly] = g.vertical ? [52, b - 10] : [b, 92]
        const [ox2, oy2] = g.vertical ? [g.spanEnd - 4, b - 10] : [b, g.spanEnd - 14]
        return (
          <g key={rule.full}>
            <path
              className={`${styles.boundary} ${matched ? styles.boundaryMatched : ''}`}
              d={`M ${x1} ${y1} L ${x2} ${y2}`}
            />
            <text
              className={`${styles.ruleLabel} ${matched ? styles.ruleLabelMatched : ''}`}
              x={lx}
              y={ly}
              textAnchor={g.vertical ? 'start' : 'middle'}
            >
              {rule.short}
            </text>
            <text
              className={styles.order}
              x={ox2}
              y={oy2}
              textAnchor={g.vertical ? 'end' : 'middle'}
            >
              {i + 1}
            </text>
          </g>
        )
      })}

      {/* Crossing ticks: every boundary the request passed without matching. */}
      {ruleSet.slice(0, ruleIndex).map((rule, i) => {
        const b = g.boundary(i)
        const [x1, y1] = pt(g, b, (g.vertical ? g.ox : g.oy) - 6)
        const [x2, y2] = pt(g, b, (g.vertical ? g.ox : g.oy) + 6)
        return (
          <path
            key={`x-${rule.full}`}
            className={`${styles.crossing} ${crossTone[clearance]}`}
            d={`M ${x1} ${y1} L ${x2} ${y2}`}
          />
        )
      })}

      {/* Origin: the local listener every request starts from. */}
      <circle className={styles.originMark} cx={oxp} cy={oyp} r={5} />
      <path
        className={styles.tick}
        d={`M ${oxp - 9} ${oyp} L ${oxp - 5} ${oyp} M ${oxp} ${oyp - 9} L ${oxp} ${oyp - 5}`}
      />
      <text
        className={styles.originLabel}
        x={portrait ? g.ox + 12 : g.ox - 8}
        y={portrait ? g.oy - 12 : g.oy - 16}
        textAnchor={portrait ? 'start' : 'start'}
      >
        {origin}
      </text>

      {/* The route. Keyed so the draw replays on every pick. */}
      <path
        key={`route-${ruleIndex}-${clearance}`}
        className={`${styles.route} ${routeTone[clearance]}`}
        d={routePath(g, ruleIndex, clearance)}
        style={{ '--route-len': routeLength(g, ruleIndex, clearance) } as CSSProperties}
      />
      <polygon
        key={`head-${ruleIndex}-${clearance}`}
        className={`${styles.head} ${headTone[clearance]}`}
        points={head(g, ruleIndex, clearance)}
      />
    </svg>
  )
}

export function RoutingChart({ content }: { content: SiteContent }) {
  const { destinations, pick, matched, clearanceNames, caption } = content.plate
  const [selected, setSelected] = useState(0)
  const groupName = useId()
  const destination = destinations[selected]
  const rule = content.plate.ruleSet[destination.ruleIndex]

  return (
    <div className={styles.wrap}>
      <div className={`plate plate--graticule plate--ticked ${styles.plate}`}>
        <Sheet
          g={LANDSCAPE}
          content={content}
          ruleIndex={destination.ruleIndex}
          clearance={destination.clearance}
          portrait={false}
        />
        <Sheet
          g={PORTRAIT}
          content={content}
          ruleIndex={destination.ruleIndex}
          clearance={destination.clearance}
          portrait
        />

        <fieldset className={styles.picker}>
          <legend className={`chartLabel ${styles.pickerLegend}`}>{pick}</legend>
          <div className={styles.options}>
            {destinations.map((item, index) => (
              <span className={styles.option} key={item.host}>
                <input
                  type="radio"
                  name={groupName}
                  id={`${groupName}-${index}`}
                  checked={index === selected}
                  onChange={() => setSelected(index)}
                />
                <label className={styles.optionLabel} htmlFor={`${groupName}-${index}`}>
                  {item.host}
                </label>
              </span>
            ))}
          </div>
        </fieldset>

        <div className={styles.verdict} aria-live="polite">
          <p className={styles.verdictHead}>
            <span className="chartLabel">{matched}</span>
            <span className={styles.verdictRule}>{rule.full}</span>
            <span
              className={`${styles.verdictClearance} ${clearanceTone[destination.clearance]}`}
            >
              {clearanceNames[destination.clearance]}
            </span>
          </p>
          <p className={styles.verdictNote}>{destination.note}</p>
        </div>
      </div>
      <p className={styles.caption}>{caption}</p>
    </div>
  )
}
