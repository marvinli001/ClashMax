import { en } from '@/lib/content.en'
import { zh } from '@/lib/content.zh'
import type { SiteContent } from '@/lib/content'
import { FALLBACK_RELEASE } from '@/lib/release'
import { LINKS, localeUrl } from '@/lib/site'

export const dynamic = 'force-static'

/**
 * /llms.txt, the plain-text summary answer engines read instead of the page.
 *
 * Built from the same content records as the page, so it cannot state a fact
 * the page does not: the summary, features, install steps, boundaries, and
 * FAQ are the visible copy, in both languages.
 */
const section = (content: SiteContent) =>
  [
    `## ${content.faq.heading}`,
    '',
    ...content.faq.items.flatMap((item) => [`### ${item.question}`, '', item.answer, '']),
    `## ${content.approach.heading}`,
    '',
    ...content.approach.steps.map((step, index) => `${index + 1}. ${step.title}: ${step.detail}`),
    '',
    `## ${content.restricted.heading}`,
    '',
    ...content.restricted.boundaries.map((boundary) => `- ${boundary.title}: ${boundary.detail}`),
    '',
  ].join('\n')

export function GET() {
  const body = [
    `# ${en.meta.siteName}`,
    '',
    `> ${en.meta.description}`,
    '',
    `- Latest release: ${FALLBACK_RELEASE.appVersion} (build ${FALLBACK_RELEASE.appBuild}), bundled Mihomo ${FALLBACK_RELEASE.mihomoVersion}`,
    '- Platform: macOS 15 or later, Apple Silicon and Intel',
    '- License: GPL-3.0, free, no account, no telemetry',
    '',
    '## Links',
    '',
    `- [Website (English)](${localeUrl('en')})`,
    `- [Website (简体中文)](${localeUrl('zh')})`,
    `- [Download the latest release](${LINKS.releases})`,
    `- [Source code](${LINKS.repo})`,
    `- [Issues](${LINKS.issues})`,
    `- [Discussions](${LINKS.discussions})`,
    `- [Security policy](${LINKS.security})`,
    `- [Mihomo core](${LINKS.mihomo})`,
    '',
    '## Features',
    '',
    ...en.meta.featureList.map((feature) => `- ${feature}`),
    '',
    section(en),
    '---',
    '',
    `# ${zh.meta.siteName}（简体中文）`,
    '',
    `> ${zh.meta.description}`,
    '',
    '## 功能',
    '',
    ...zh.meta.featureList.map((feature) => `- ${feature}`),
    '',
    section(zh),
  ].join('\n')

  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } })
}
