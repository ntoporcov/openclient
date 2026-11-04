import { expect, test } from "bun:test"
import { createCipheriv } from "node:crypto"
import { installARDEncryptionFallback } from "../src/remote-desktop-crypto.js"

function legacy() {
  return { importKey(..._args: unknown[]): any { return "original" } }
}
const algorithm = { name: "AES-ECB" }
test("ARD HTTP fallback matches AES-128 known vector and unpadded credential blocks", () => {
  const crypto = legacy()
  installARDEncryptionFallback(crypto, false)
  const key = Buffer.from("000102030405060708090a0b0c0d0e0f", "hex")
  const cipher = crypto.importKey("raw", key, algorithm, false, ["encrypt"])
  expect(Buffer.from(cipher.encrypt(algorithm, Buffer.from("00112233445566778899aabbccddeeff", "hex"))).toString("hex"))
    .toBe("69c4e0d86a7b0430d8cdb78070b4c55a")
  const credentials = new Uint8Array(128).map((_, i) => i)
  const reference = createCipheriv("aes-128-ecb", key, null).setAutoPadding(false)
  expect(Buffer.from(cipher.encrypt(algorithm, credentials))).toEqual(Buffer.concat([reference.update(credentials), reference.final()]))
  expect(() => cipher.encrypt(algorithm, new Uint8Array(17))).toThrow()
  expect(() => crypto.importKey("raw", new Uint8Array(15), algorithm, false, ["encrypt"])).toThrow()
  expect(() => crypto.importKey("raw", key, algorithm, false, ["decrypt"])).toThrow()
})
test("secure origins and unrelated algorithms retain noVNC implementation", () => {
  const crypto = legacy()
  const original = crypto.importKey
  installARDEncryptionFallback(crypto, true)
  expect(crypto.importKey).toBe(original)
  installARDEncryptionFallback(crypto, false)
  expect(crypto.importKey("raw", new Uint8Array(), { name: "DES" }, false, [])).toBe("original")
})
