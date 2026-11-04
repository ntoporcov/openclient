import { createServer, type Socket } from "node:net"

/** Minimal RFB 3.8 desktop for transport/renderer tests; never connects to a real desktop. */
export async function startVNCFixture() {
  const events: Array<{ type: string; key?: number; down?: boolean; x?: number; y?: number; buttons?: number }> = []
  const clients = new Set<Socket>()
  const server = createServer((socket) => {
    clients.add(socket)
    socket.on("error", () => {})
    socket.on("close", () => clients.delete(socket))
    socket.write("RFB 003.008\n")
    let buffer = Buffer.alloc(0)
    let phase = 0
    let redShift = 16, greenShift = 8, blueShift = 0
    socket.on("data", (data) => {
      buffer = Buffer.concat([buffer, data])
      while (buffer.length) {
        if (phase === 0) {
          if (buffer.length < 12) return
          buffer = buffer.subarray(12)
          socket.write(Buffer.from([1, 1])) // One security type: None, fixture only.
          phase = 1
        } else if (phase === 1) {
          buffer = buffer.subarray(1)
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
