import { ecb } from "@noble/ciphers/aes.js"

type Algorithm = { name: string }
type LegacyCrypto = {
  importKey(format: string, keyData: Uint8Array, algorithm: Algorithm, extractable: boolean, usages: string[]): unknown
}

/**
 * ARD mandates AES-128-ECB for its 128-byte credential block. noVNC implements
 * that via WebCrypto, which WebKit omits on HTTP LAN/VPN origins. Keep the same
 * wire encryption using noble's AES implementation; don't fake a secure context
 * or replace the browser's crypto API. Secure origins retain noVNC's implementation.
 */
export function installARDEncryptionFallback(crypto: LegacyCrypto, hasWebCrypto: boolean): void {
  if (hasWebCrypto) return
  const original = crypto.importKey.bind(crypto)
  crypto.importKey = (format, data, algorithm, extractable, usages) => {
    if (algorithm.name !== "AES-ECB") return original(format, data, algorithm, extractable, usages)
    if (format !== "raw" || data.byteLength !== 16 || usages.length !== 1 || usages[0] !== "encrypt") {
      throw new Error("Unsupported ARD encryption key")
    }
    const key = new Uint8Array(data)
    return {
      algorithm: { name: "AES-ECB" },
      encrypt(requested: Algorithm, plaintext: Uint8Array) {
        if (requested.name !== "AES-ECB" || plaintext.byteLength % 16 !== 0) {
          throw new Error("Invalid ARD encryption block")
        }
        return ecb(key, { disablePadding: true }).encrypt(plaintext)
      },
    }
  }
}
