import type { SiteContent } from '@/lib/content'
import { ReleaseProvider } from './ReleaseProvider'
import { SiteHeader } from './SiteHeader'
import { Hero } from './Hero'
import { VersionStrip } from './VersionStrip'
import { DashboardFigure } from './DashboardFigure'
import { ConfigPlate } from './ConfigPlate'
import { Legend } from './Legend'
import { Replicas } from './Replicas'
import { Restricted } from './Restricted'
import { Approach } from './Approach'
import { Close } from './Close'
import { SiteFooter } from './SiteFooter'

/**
 * One sheet, read top to bottom, in whichever language was authored for it.
 * Both locales render this component with their own content record, so a
 * layout improvement lands in both and neither can silently fall behind.
 */
export function SitePage({ content }: { content: SiteContent }) {
  return (
    <ReleaseProvider>
      <a className="skip" href="#main">
        {content.nav.skipToContent}
      </a>
      <SiteHeader content={content} />
      <main id="main">
        <Hero content={content} />
        <VersionStrip content={content} />
        <DashboardFigure content={content} />
        <ConfigPlate content={content} />
        <Legend content={content} />
        <Replicas content={content} />
        <Restricted content={content} />
        <Approach content={content} />
        <Close content={content} />
      </main>
      <SiteFooter content={content} />
    </ReleaseProvider>
  )
}
