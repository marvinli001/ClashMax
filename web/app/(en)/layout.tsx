import type { Metadata, Viewport } from 'next'
import type { ReactNode } from 'react'
import { en } from '@/lib/content.en'
import { buildMetadata, viewport as themeViewport } from '@/lib/metadata'
import { LanguageRouter } from '@/components/LanguageRouter'
import { fontVariables } from '../fonts'
import '../globals.css'

export const metadata: Metadata = buildMetadata(en)
export const viewport: Viewport = themeViewport

/**
 * English root layout, serving `/`.
 *
 * This is one of two root layouts. The Chinese page is not this document with
 * its text swapped out; it is its own document with its own `lang`, metadata,
 * and hreflang, rendered from its own content record.
 */
export default function EnglishRootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang={en.htmlLang} className={fontVariables}>
      <head>
        <LanguageRouter />
      </head>
      <body>{children}</body>
    </html>
  )
}
