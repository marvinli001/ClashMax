import type { MetadataRoute } from 'next'
import { SITE_ORIGIN } from '@/lib/site'

export const dynamic = 'force-static'

/**
 * Every crawler may read the whole site. Answer-engine crawlers are named
 * explicitly as well, so a reader of this file sees they are welcome rather
 * than merely not refused.
 */
const ANSWER_ENGINES = [
  'GPTBot',
  'OAI-SearchBot',
  'ChatGPT-User',
  'ClaudeBot',
  'Claude-SearchBot',
  'Claude-User',
  'PerplexityBot',
  'Google-Extended',
  'Applebot-Extended',
  'Bytespider',
]

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: '*', allow: '/' }, { userAgent: ANSWER_ENGINES, allow: '/' }],
    sitemap: `${SITE_ORIGIN}/sitemap.xml`,
  }
}
