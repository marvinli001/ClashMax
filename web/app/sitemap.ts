import type { MetadataRoute } from 'next'
import { LOCALES } from '@/lib/content'
import { FALLBACK_RELEASE } from '@/lib/release'
import { localeUrl } from '@/lib/site'

export const dynamic = 'force-static'

/**
 * Both locales, each carrying the full hreflang pair, dated to the release the
 * page was last cut for: that is when its facts last changed.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  const languages = { en: localeUrl('en'), 'zh-Hans': localeUrl('zh'), 'x-default': localeUrl('en') }
  return LOCALES.map((locale) => ({
    url: localeUrl(locale),
    lastModified: FALLBACK_RELEASE.appPublishedAt,
    changeFrequency: 'weekly',
    priority: locale === 'en' ? 1 : 0.9,
    alternates: { languages },
  }))
}
