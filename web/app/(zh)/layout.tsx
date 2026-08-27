import type { Metadata, Viewport } from 'next'
import type { ReactNode } from 'react'
import { zh } from '@/lib/content.zh'
import { buildMetadata, viewport as themeViewport } from '@/lib/metadata'
import { fontVariables } from '../fonts'
import '../globals.css'

export const metadata: Metadata = buildMetadata(zh)
export const viewport: Viewport = themeViewport

/**
 * Simplified Chinese root layout, serving `/zh/`.
 *
 * No language redirect runs here: a direct link to this page is always
 * honoured. Only the canonical English route forwards a visitor.
 */
export default function ChineseRootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang={zh.htmlLang} className={fontVariables}>
      <body>{children}</body>
    </html>
  )
}
