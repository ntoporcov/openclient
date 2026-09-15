export function sanitizeSourceEndpoint(value) {
  let url;
  try { url = value instanceof URL ? value : new URL(value); } catch { return null; }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.pathname !== "/" || url.search || url.hash) return null;
  const port = url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80;
  if (!Number.isInteger(port) || port < 1 || port > 65_535) return null;
  return { protocol: url.protocol.slice(0, -1), port };
}

export function validateSourceEndpoint(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some((key) => !["protocol", "port"].includes(key))) return null;
  if (!(["http", "https"].includes(value.protocol)) || !Number.isInteger(value.port) || value.port < 1 || value.port > 65_535) return null;
  return { protocol: value.protocol, port: value.port };
}
