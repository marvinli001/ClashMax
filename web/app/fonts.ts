/**
 * The chart's lettering, self-hosted at build time by next/font.
 *
 * Archivo is the text face: a grotesque with the flat, slightly condensed
 * character of chart lettering and a real narrow companion, which is what the
 * legend labels need. IBM Plex Mono carries rule syntax, YAML keys, and
 * measured figures. CJK falls through to the platform faces declared in
 * globals.css, because no webfont worth shipping covers it at this weight.
 */
import { Archivo, Archivo_Narrow, IBM_Plex_Mono } from 'next/font/google'

const archivo = Archivo({
  subsets: ['latin'],
  variable: '--font-archivo',
  display: 'swap',
})

const archivoNarrow = Archivo_Narrow({
  subsets: ['latin'],
  variable: '--font-archivo-narrow',
  display: 'swap',
})

const plexMono = IBM_Plex_Mono({
  subsets: ['latin'],
  weight: ['400', '500'],
  variable: '--font-plex-mono',
  display: 'swap',
})

export const fontVariables = `${archivo.variable} ${archivoNarrow.variable} ${plexMono.variable}`
