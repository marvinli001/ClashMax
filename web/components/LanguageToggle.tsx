'use client'

import type { Locale } from '@/lib/content'
import { LANG_STORAGE_KEY, localePath } from '@/lib/site'
import styles from './LanguageToggle.module.css'

/**
 * A real link to the other locale's real page, so it works with JavaScript
 * off. The click handler only records the choice, which is what stops `/`
 * from bouncing a Chinese-preferring visitor who deliberately chose English.
 */
export function LanguageToggle({
  current,
  label,
  otherName,
}: {
  current: Locale
  label: string
  otherName: string
}) {
  const other: Locale = current === 'en' ? 'zh' : 'en'

  const remember = () => {
    try {
      localStorage.setItem(LANG_STORAGE_KEY, other)
      sessionStorage.setItem(`${LANG_STORAGE_KEY}-routed`, '1')
    } catch {
      /* Private mode or storage disabled: the link still navigates. */
    }
  }

  return (
    <a
      className={styles.toggle}
      href={localePath(other)}
      hrefLang={other === 'en' ? 'en' : 'zh-Hans'}
      lang={other === 'en' ? 'en' : 'zh-Hans'}
      aria-label={`${label}: ${otherName}`}
      onClick={remember}
    >
      <span className={styles.mark} aria-hidden="true">
        {current === 'en' ? 'EN' : '中'}
      </span>
      <span className={styles.other}>{otherName}</span>
    </a>
  )
}
