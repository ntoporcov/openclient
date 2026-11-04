import { createServer, type Socket } from "node:net"
import { getDiffieHellman, createDecipheriv, createHash } from "node:crypto"

/** Minimal RFB 3.8 desktop for transport/renderer tests; never connects to a real desktop. */
export async function startVNCFixture(credentials?: { username: string; password: string }) {
  const events: Array<{ type: string; key?: number; down?: boolean; x?: number; y?: number; buttons?: number }> = []
  const clients = new Set<Socket>()
  const server = createServer((socket) => {
    clients.add(socket)
    socket.on("error", () => {})
    socket.on("close", () => clients.delete(socket))
    socket.write("RFB 003.008\n")
    let buffer = Buffer.alloc(0)
    let phase = 0
    const dh = credentials ? getDiffieHellman("modp14") : undefined
    const publicKey = dh?.generateKeys()
    let redShift = 16, greenShift = 8, blueShift = 0
    socket.on("data", (data) => {
      buffer = Buffer.concat([buffer, data])
      while (buffer.length) {
        if (phase === 0) {
          if (buffer.length < 12) return
          buffer = buffer.subarray(12)
          socket.write(Buffer.from([1, credentials ? 30 : 1]))
          phase = 1
        } else if (phase === 1) {
          buffer = buffer.subarray(1)
          if (dh && publicKey) {
            const header = Buffer.alloc(4)
            header.writeUInt16BE(2, 0)
            header.writeUInt16BE(publicKey.length, 2)
            socket.write(Buffer.concat([header, dh.getPrime(), publicKey]))
            phase = 4
            continue
          }
          socket.write(Buffer.alloc(4))
          phase = 2
        } else if (phase === 4 && dh && publicKey && credentials) {
          if (buffer.length < 128 + publicKey.length) return
          const secret = dh.computeSecret(buffer.subarray(128, 128 + publicKey.length))
          const key = createHash("md5").update(secret).digest()
          const decipher = createDecipheriv("aes-128-ecb", key, null).setAutoPadding(false)
          const clear = Buffer.concat([decipher.update(buffer.subarray(0, 128)), decipher.final()])
          const field = (offset: number) => clear.subarray(offset, offset + 64).toString().split("\0")[0]
          const accepted = field(0) === credentials.username && field(64) === credentials.password
          events.push({ type: accepted ? "authenticated" : "authentication-failed" })
          buffer = buffer.subarray(128 + publicKey.length)
          if (!accepted) {
            const reason = Buffer.from("Fixture credentials rejected")
            const result = Buffer.alloc(8)
            result.writeUInt32BE(1, 0); result.writeUInt32BE(reason.length, 4)
            socket.end(Buffer.concat([result, reason]))
            return
          }
          socket.write(Buffer.alloc(4))
          phase = 2
        } else if (phase === 2) {
          buffer = buffer.subarray(1)
          const name = Buffer.from("OpenClient test desktop")
          const init = Buffer.alloc(24)
          init.writeUInt16BE(320, 0); init.writeUInt16BE(180, 2)
          Buffer.from([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]).copy(init, 4)
          init.writeUInt32BE(name.length, 20)
          socket.write(Buffer.concat([init, name]))
          phase = 3
        } else {
          const type = buffer[0]
          let length = 0
          if (type === 0) length = 20
          else if (type === 2) { if (buffer.length < 4) return; length = 4 + buffer.readUInt16BE(2) * 4 }
          else if (type === 3) length = 10
          else if (type === 4) length = 8
          else if (type === 5) length = 6
          else if (type === 6) { if (buffer.length < 8) return; length = 8 + buffer.readUInt32BE(4) }
          else { socket.destroy(); return }
          if (buffer.length < length) return
          const message = buffer.subarray(0, length)
          buffer = buffer.subarray(length)
          if (type === 0) {
            redShift = message[14]!; greenShift = message[15]!; blueShift = message[16]!
          }
          if (type === 3 && message[1] === 0) {
            const header = Buffer.alloc(16)
            header.writeUInt16BE(1, 2)
            header.writeUInt16BE(320, 8); header.writeUInt16BE(180, 10)
            const pixels = Buffer.alloc(320 * 180 * 4)
            for (let y = 0; y < 180; y++) for (let x = 0; x < 320; x++) {
              const offset = (y * 320 + x) * 4
              pixels.writeUInt32LE(((x % 256) << redShift) | (y << greenShift) | (180 << blueShift), offset)
            }
            socket.write(Buffer.concat([header, pixels]))
          }
          if (type === 4) events.push({ type: "key", key: message.readUInt32BE(4), down: message[1] === 1 })
          if (type === 5) events.push({ type: "pointer", buttons: message[1], x: message.readUInt16BE(2), y: message.readUInt16BE(4) })
        }
      }
    })
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Fixture failed to bind")
  return {
    port: address.port, events,
    async stop() {
      for (const socket of clients) socket.destroy()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    },
  }
}
