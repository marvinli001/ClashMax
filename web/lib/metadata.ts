import type { Metadata } from 'next'
import type { SiteContent } from './content'
import { asset, localeUrl, SITE_ORIGIN } from './site'

/**
 * Both locales are real documents, so both get real metadata: their own title,
 * description, canonical URL, and a complete hreflang pair pointing at each
 * other. The incumbent page had one document and swapped its text, so search
 * engines only ever saw English.
 */
export function buildMetadata(content: SiteContent): Metadata {
  const canonical = localeUrl(content.locale)
  return {
    metadataBase: new URL(SITE_ORIGIN),
    title: content.meta.title,
    description: content.meta.description,
    applicationName: content.meta.siteName,
    alternates: {
      canonical,
      languages: {
        en: localeUrl('en'),
        'zh-Hans': localeUrl('zh'),
        'x-default': localeUrl('en'),
      },
    },
    openGraph: {
      type: 'website',
      siteName: content.meta.siteName,
      title: content.meta.title,
      description: content.meta.description,
      url: canonical,
      locale: content.locale === 'en' ? 'en_US' : 'zh_CN',
      images: [{ url: asset('/social-preview.png'), width: 1280, height: 640, alt: content.meta.siteName }],
    },
    twitter: {
      card: 'summary_large_image',
      title: content.meta.title,
      description: content.meta.description,
      images: [asset('/social-preview.png')],
    },
    icons: {
      icon: asset('/clashmax-icon.png'),
      apple: asset('/clashmax-icon.png'),
    },
  }
}

export const viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f1f3ef' },
    { media: '(prefers-color-scheme: dark)', color: '#0d1115' },
  ],
}
