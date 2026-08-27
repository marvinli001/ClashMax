'use client'

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import {
  INITIAL_RELEASE_STATE,
  fetchAppRelease,
  fetchMihomoRelease,
  type ReleaseState,
} from '@/lib/release'

const ReleaseContext = createContext<ReleaseState>(INITIAL_RELEASE_STATE)

export function useRelease(): ReleaseState {
  return useContext(ReleaseContext)
}

/**
 * Release facts, committed then corrected.
 *
 * The page is prerendered with the committed values in `lib/release.ts`, so it
 * is complete and downloadable with JavaScript off or the API rate-limited.
 * On mount the two release endpoints are asked for the truth and the values are
 * replaced in place.
 */
export function ReleaseProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<ReleaseState>(INITIAL_RELEASE_STATE)

  useEffect(() => {
    const controller = new AbortController()
    const apply = (patch: Partial<ReleaseState>) =>
      setState((current) => ({ ...current, ...patch }))

    fetchAppRelease(controller.signal).then(apply, () => {})
    fetchMihomoRelease(controller.signal).then(apply, () => {})

    return () => controller.abort()
  }, [])

  return <ReleaseContext.Provider value={state}>{children}</ReleaseContext.Provider>
}
