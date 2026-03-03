declare global {
  interface Window {
    __XFTP_I18N__?: Record<string, string>
  }
}

export function t(key: string, fallback: string): string {
  return window.__XFTP_I18N__?.[key] ?? fallback
}
