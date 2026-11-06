import { expect, test } from "bun:test"
import { createServer } from "node:net"
import { spawn } from "node:child_process"
import { once } from "node:events"
import { clipboardObserverScript, isLocalDesktopHost, observeMacClipboard, type ClipboardObserver } from "../src/remote-desktop-clipboard.js"
import { RemoteDesktopSessions } from "../src/remote-desktop-session.js"

test("host clipboard accepts local targets and rejects other computers", () => {
  expect(isLocalDesktopHost("127.0.0.1")).toBe(true)
  expect(isLocalDesktopHost("::1")).toBe(true)
  expect(isLocalDesktopHost("localhost")).toBe(true)
  expect(isLocalDesktopHost("192.0.2.47")).toBe(false)
  expect(isLocalDesktopHost("another-mac.example")).toBe(false)
})

test.skipIf(process.platform !== "darwin")("clipboard requires negotiated opt-in, stops with viewer, ignores late callbacks", async () => {
  const server = createServer((socket) => { socket.on("error", () => {}); socket.resume() })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("No fixture port")
  let starts = 0, stops = 0
  let deliver: (text: string) => void = () => {}
  const observe: ClipboardObserver = (onText, onStatus) => {
    starts++
    deliver = onText
    onStatus(true)
    return () => { stops++ }
  }
  const session = new RemoteDesktopSessions(`vnc://127.0.0.1:${address.port}`, undefined, true, observe)
  const messages: unknown[] = []
  const peer = { data: { desktopTicket: "test", clipboard: true }, send: (text: string) => { messages.push(JSON.parse(text)); return 1 },
    sendBinary: () => 1, getBufferedAmount: () => 0, close: () => {} } as never
  try {
    session.open(peer)
    expect(messages).toEqual([{ type: "clipboard.capability", available: true }])
    expect(starts).toBe(0)
    session.message(peer, '{"type":"clipboard.subscribe"}')
    session.message(peer, '{"type":"clipboard.subscribe"}')
    expect(starts).toBe(1)
    deliver("A Mac copy — 🖥")
    expect(messages.at(-1)).toEqual({ type: "clipboard.text", text: "A Mac copy — 🖥" })
    session.close(peer)
    expect(stops).toBe(1)
    const count = messages.length
    deliver("stale")
    expect(messages).toHaveLength(count)
    session.close(peer)
    expect(stops).toBe(1)
  } finally {
    session.stop()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
})

// Explicit live validation only. Preserve every original pasteboard flavor and
// restore it unless the user has copied something else while the test was running.
test.skipIf(process.env.OPENCLIENT_LIVE_CLIPBOARD_TEST !== "1" || process.platform !== "darwin")(
  "native Mac pasteboard change reaches the production observer", async () => {
    const text = `OpenClient clipboard probe ${crypto.randomUUID()} — 🖥`
    // Named pasteboard isolates this test from Simulator's general-pasteboard
    // sync. Set OPENCLIENT_GENERAL_CLIPBOARD_TEST=1 for the actual desktop board.
    const board = process.env.OPENCLIENT_GENERAL_CLIPBOARD_TEST === "1" ? "$.NSPasteboard.generalPasteboard"
      : `$.NSPasteboard.pasteboardWithName($("openclient-test-${crypto.randomUUID()}"))`
    let stop = () => {}
    let captured!: (text: string) => void
    const capture = new Promise<string>((resolve) => { captured = resolve })
    await new Promise<void>((resolve, reject) => {
      stop = observeMacClipboard((value) => { if (value === text) captured(value) },
        (ready) => ready ? resolve() : reject(new Error("Mac observer failed")),
        clipboardObserverScript.replace("$.NSPasteboard.generalPasteboard", board))
    })
    const script = `
ObjC.import('AppKit'); ObjC.import('Foundation');
var board = ${board};
var items = board.pasteboardItems, saved = [];
for (var i = 0; i < items.count; i++) {
  var original = items.objectAtIndex(i), copy = $.NSPasteboardItem.alloc.init;
  var types = original.types;
  for (var j = 0; j < types.count; j++) {
    var type = types.objectAtIndex(j), data = original.dataForType(type);
    if (!data.isNil()) copy.setDataForType(data, type);
  }
  saved.push(copy);
}
var written = -1;
try {
  board.clearContents;
  var success = board.setStringForType($(${JSON.stringify(text)}), $.NSPasteboardTypeString);
  written = board.changeCount;
  var check = board.stringForType($.NSPasteboardTypeString);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData($(JSON.stringify({success: success, readable: !check.isNil()}) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(2));
} finally {
  if (board.changeCount === written) { board.clearContents; if (saved.length) board.writeObjects($(saved)); }
}
`
    const writer = spawn("/usr/bin/osascript", ["-l", "JavaScript", "-e", script], { stdio: ["pipe", "pipe", "ignore"] })
    const exited = once(writer, "exit")
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const [status] = await once(writer.stdout, "data")
      expect(JSON.parse(String(status))).toEqual({ success: true, readable: true })
      const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("No Mac clipboard event")), 5000) })
      expect(await Promise.race([capture, timeout])).toBe(text)
    } finally {
      clearTimeout(timer)
      stop()
      writer.stdin.end("\n")
      const [code] = await exited
      expect(code).toBe(0)
    }
  }, 15_000)
