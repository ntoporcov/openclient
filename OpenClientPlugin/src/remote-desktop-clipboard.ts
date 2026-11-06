import { spawn } from "node:child_process"
import { networkInterfaces } from "node:os"
import { StringDecoder } from "node:string_decoder"

export type ClipboardObserver = (onText: (text: string) => void, onStatus: (ready: boolean) => void) => () => void

export function isLocalDesktopHost(host: string): boolean {
  if (["localhost", "127.0.0.1", "::1"].includes(host.toLowerCase())) return true
  return Object.values(networkInterfaces()).some((entries) => entries?.some((entry) => entry.address === host))
}

// NSPasteboard has no cross-process change notification. Keep one AppKit process
// per active viewer and inspect only changeCount every 100 ms; read text on change.
// JXA ships with macOS, so this needs neither Xcode nor an installed helper binary.
export const clipboardObserverScript = `
ObjC.import('AppKit');
ObjC.import('Foundation');
function emit(value) {
  var line = $(JSON.stringify(value) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(line);
}
var board = $.NSPasteboard.generalPasteboard;
var count = board.changeCount;
emit({type: 'ready'});
while (true) {
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
  var next = board.changeCount;
  if (next === count) continue;
  count = next;
  var value = board.stringForType($.NSPasteboardTypeString);
  if (value.isNil()) continue;
  var bytes = value.lengthOfBytesUsingEncoding($.NSUTF8StringEncoding);
  if (bytes > 0 && bytes <= 65536 && board.changeCount === next)
    emit({type: 'text', text: ObjC.unwrap(value)});
}
`

export function observeMacClipboard(onText: (text: string) => void, onStatus: (ready: boolean) => void,
  script = clipboardObserverScript): () => void {
  const child = spawn("/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
    { stdio: ["ignore", "pipe", "ignore"] })
  const decoder = new StringDecoder("utf8")
  let pending = ""
  let stopped = false
  const stop = () => {
    if (stopped) return
    stopped = true
    pending = ""
    child.kill()
  }
  const failed = () => { if (!stopped) { stop(); onStatus(false) } }
  child.on("error", failed)
  child.on("exit", failed)
  child.stdout.on("data", (chunk: Buffer) => {
    if (stopped) return
    pending += decoder.write(chunk)
    // JSON can escape every byte of a 64 KiB text item. Bound partial frames too.
    if (pending.length > 512 * 1024) { failed(); return }
    let newline: number
    while ((newline = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, newline)
      pending = pending.slice(newline + 1)
      try {
        const value = JSON.parse(line)
        if (value.type === "ready") onStatus(true)
        else if (value.type === "text" && typeof value.text === "string"
          && Buffer.byteLength(value.text, "utf8") > 0 && Buffer.byteLength(value.text, "utf8") <= 65_536) onText(value.text)
      } catch { failed(); return }
    }
  })
  return stop
}
