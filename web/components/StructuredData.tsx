import type { SiteContent } from '@/lib/content'
import { FALLBACK_RELEASE } from '@/lib/release'
import { LINKS, localeUrl, SITE_ORIGIN } from '@/lib/site'

const AUTHOR_URL = 'https://github.com/marvinli001'

/**
 * Schema.org description of the page, as one JSON-LD graph.
 *
 * Every value here is something the page itself says: the app record repeats
 * the hero, the release figures are the committed fallback facts, and the
 * FAQPage repeats the visible answers word for word. Nothing is invented for
 * crawlers alone - no rating, no review count, no download total.
 */
export function StructuredData({ content }: { content: SiteContent }) {
  const url = localeUrl(content.locale)
  const app = `${SITE_ORIGIN}/#app`
  const author = `${SITE_ORIGIN}/#author`
  const website = `${SITE_ORIGIN}/#website`
  const screenshot = `${SITE_ORIGIN}/app-home-${content.locale}.png`

  const graph = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'Person',
        '@id': author,
        name: 'marvinli001',
        url: AUTHOR_URL,
      },
      {
        '@type': 'WebSite',
        '@id': website,
        url: `${SITE_ORIGIN}/`,
        name: content.meta.siteName,
        inLanguage: ['en', 'zh-Hans'],
        publisher: { '@id': author },
      },
      {
        '@type': 'SoftwareApplication',
        '@id': app,
        name: content.meta.siteName,
        description: content.meta.description,
        url,
        applicationCategory: 'UtilitiesApplication',
        applicationSubCategory: content.meta.category,
        operatingSystem: 'macOS 15 or later',
        processorRequirements: 'Apple Silicon or Intel',
        softwareRequirements: 'Bundled Mihomo core',
        softwareVersion: FALLBACK_RELEASE.appVersion.replace(/^v/, ''),
        dateModified: FALLBACK_RELEASE.appPublishedAt,
        downloadUrl: LINKS.releases,
        installUrl: LINKS.releases,
        releaseNotes: LINKS.releases,
        license: 'https://www.gnu.org/licenses/gpl-3.0.html',
        isAccessibleForFree: true,
        offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
        image: `${SITE_ORIGIN}/clashmax-icon.png`,
        screenshot,
        featureList: content.meta.featureList,
        keywords: content.meta.keywords.join(', '),
        inLanguage: ['en', 'zh-Hans'],
        author: { '@id': author },
        sameAs: [LINKS.repo],
      },
      {
        '@type': 'SoftwareSourceCode',
        '@id': `${SITE_ORIGIN}/#source`,
        name: `${content.meta.siteName} source code`,
        codeRepository: LINKS.repo,
        programmingLanguage: 'Swift',
        runtimePlatform: 'macOS',
        license: 'https://www.gnu.org/licenses/gpl-3.0.html',
        targetProduct: { '@id': app },
        author: { '@id': author },
      },
      {
        '@type': 'WebPage',
        '@id': `${url}#webpage`,
        url,
        name: content.meta.title,
        description: content.meta.description,
        inLanguage: content.htmlLang,
        isPartOf: { '@id': website },
        about: { '@id': app },
        primaryImageOfPage: screenshot,
      },
      {
        '@type': 'FAQPage',
        '@id': `${url}#faq`,
        url: `${url}#faq`,
        inLanguage: content.htmlLang,
        isPartOf: { '@id': `${url}#webpage` },
        mainEntity: content.faq.items.map((item) => ({
          '@type': 'Question',
          name: item.question,
          acceptedAnswer: { '@type': 'Answer', text: item.answer },
        })),
      },
    ],
  }

  // `<` is escaped so no string in the copy can ever close the script element.
  const json = JSON.stringify(graph).replace(/</g, '\\u003c')
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: json }} />
}
