/**
 * Chart symbology.
 *
 * Authored rather than pulled from an icon library: a sectional chart's marks
 * (compass rose, waypoint triangle, boundary tick, restricted hatch) do not
 * exist in any UI icon set, and a generic glyph next to chart line work reads
 * as a sticker. One stroke weight, one cap style, one 24-unit grid throughout.
 */

import type { SVGProps } from 'react'

type MarkProps = SVGProps<SVGSVGElement> & { size?: number }

function Mark({ size = 20, children, ...rest }: MarkProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="square"
      strokeLinejoin="miter"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  )
}

/** Downloads: an arrow onto a hard deck line. */
export const MarkDownload = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M12 3v12" />
    <path d="M7 10.5 12 15.5 17 10.5" />
    <path d="M4 20h16" />
  </Mark>
)

/** Source repository: three stacked plates. */
export const MarkSource = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M12 3 21 7.5 12 12 3 7.5 12 3Z" />
    <path d="M3 12l9 4.5L21 12" />
    <path d="M3 16.5 12 21l9-4.5" />
  </Mark>
)

/** Report: a flagged marker. */
export const MarkReport = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M6 21V3" />
    <path d="M6 4h12l-3 4 3 4H6" />
  </Mark>
)

/** Chart surfaces, one per page in the app. Same grid, same stroke. */

export const MarkDashboard = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M3 19h18" />
    <path d="M3 19l5-7 4 3 5-8 4 5" />
    <circle cx="8" cy="12" r="1.15" />
  </Mark>
)

export const MarkProfiles = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M5 3h9l5 5v13H5V3Z" />
    <path d="M14 3v5h5" />
    <path d="M8.5 13h7M8.5 16.5h4.5" />
  </Mark>
)

export const MarkProxies = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M4 12h5" />
    <path d="M15 12h5" />
    <path d="M12 5.5 15 12l-3 6.5L9 12l3-6.5Z" />
  </Mark>
)

export const MarkConnections = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M3 6h18M3 12h18M3 18h18" />
    <path d="M8 3.5v5M15 9.5v5M11 15.5v5" />
  </Mark>
)

export const MarkRules = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M4 5h16M4 12h11M4 19h16" />
    <path d="M18.5 9.5 21.5 12l-3 2.5" />
  </Mark>
)

export const MarkLogs = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M4 4h16v16H4z" />
    <path d="M7.5 9l2.5 2.5-2.5 2.5" />
    <path d="M12.5 14.5h4" />
  </Mark>
)

export const MarkSettings = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M4 7h16M4 17h16" />
    <circle cx="9.5" cy="7" r="2.25" />
    <circle cx="15.5" cy="17" r="2.25" />
  </Mark>
)

export const MarkMenubar = (p: MarkProps) => (
  <Mark {...p}>
    <path d="M3 5h18v14H3z" />
    <path d="M3 9h18" />
    <path d="M15.5 7h3" />
    <circle cx="12" cy="7" r="0.9" />
  </Mark>
)

/** A compass rose, used once as the page mark. */
export const MarkRose = ({ size = 22, ...rest }: MarkProps) => (
  <Mark size={size} {...rest}>
    <circle cx="12" cy="12" r="8.25" />
    <path d="M12 1.75V6M12 18v4.25M1.75 12H6M18 12h4.25" />
    <path d="M12 6.75 13.6 12 12 17.25 10.4 12 12 6.75Z" />
  </Mark>
)

export const SURFACE_MARKS = {
  dashboard: MarkDashboard,
  profiles: MarkProfiles,
  proxies: MarkProxies,
  connections: MarkConnections,
  rules: MarkRules,
  logs: MarkLogs,
  settings: MarkSettings,
  menubar: MarkMenubar,
} as const
