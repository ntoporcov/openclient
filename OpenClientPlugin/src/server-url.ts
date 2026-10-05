/** Validate the configured OpenCode origin shared by V1 and V2 hosts. */
export function configuredServerURL(value: string): URL {
  const url = new URL(value)
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("serverURL must be an HTTP(S) origin without credentials")
  }
  return url
}
