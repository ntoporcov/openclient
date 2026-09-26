import { describe, expect, test } from "bun:test"
import type { Plugin } from "@opencode/plugin"
import OpenClientPlugin from "../src/index.js"
import { setupV2, v2ServerURL } from "../src/v2.js"

describe("v2 server URL", () => {
  test("derives the host port from serve arguments, environment, and the default", () => {
    expect(v2ServerURL({}, ["node", "serve", "--port", "4310"], {}).origin).toBe("http://127.0.0.1:4310")
    expect(v2ServerURL({}, ["node", "serve", "--port=4311"], {}).port).toBe("4311")
    expect(v2ServerURL({}, ["node", "serve"], { OPENCODE_SERVER_PORT: "4312" }).port).toBe("4312")
    expect(v2ServerURL({}, ["node", "serve"], {}).port).toBe("4096")
  })

  test("requires a valid port or an explicit origin", () => {
    expect(() => v2ServerURL({}, ["node", "host"], {})).toThrow("serverURL option")
    expect(() => v2ServerURL({}, ["node", "serve", "--port", "not-a-port"], {})).toThrow("Invalid OpenCode server port")
    expect(() => v2ServerURL({}, ["node", "serve", "--port=0"], {})).toThrow("Invalid OpenCode server port")
    expect(() => v2ServerURL({}, ["node", "serve", "--port=65536"], {})).toThrow("Invalid OpenCode server port")
    expect(() => v2ServerURL({ serverURL: "ftp://127.0.0.1/" })).toThrow("HTTP(S)")
    expect(() => v2ServerURL({ serverURL: "http://user:pass@127.0.0.1/" })).toThrow("credentials")
    expect(() => v2ServerURL({ serverURL: "http://127.0.0.1/api" })).toThrow("HTTP(S)")
    expect(() => v2ServerURL({ serverURL: "http://127.0.0.1/?query=1" })).toThrow("HTTP(S)")
    expect(v2ServerURL({ serverURL: "https://example.test" }).origin).toBe("https://example.test")
  })
})

describe("v2 plugin export", () => {
  test("exports the canonical id, legacy server, and v2 setup", () => {
    expect(OpenClientPlugin.id).toBe("openclient")
    expect(typeof OpenClientPlugin.server).toBe("function")
    expect(typeof OpenClientPlugin.setup).toBe("function")
  })
})

describe("v2 setup lifecycle", () => {
  test("registers tools, supports location variants, and releases the bridge", async () => {
    const registered: Array<{ name?: string }> = []
    const context = fakeContext({ registered })
    const cleanup = await setupV2(context)
    const port = await bridgePort(45432)

    try {
      expect(registered.map((tool) => tool.name)).toEqual([
        "openclient_get_tool_list",
        "openclient_execute_tool",
      ])
      expect((await fetch(`http://127.0.0.1:${port}/openclient/v1/health`)).status).toBe(200)
    } finally {
      await cleanup()
    }

    expect((await fetch(`http://127.0.0.1:${port}/openclient/v1/health`).catch(() => undefined))?.status).not.toBe(200)

    {
      const registered: Array<{ name?: string }> = []
      const context = fakeContext({
        registered,
        location: { directory: "/workspace/project", workspaceID: "workspace-1", project: { canonical: "/workspace/project" } } as Plugin.Context["location"],
        transform: async () => { throw new Error("registration failed") },
      })

      await expect(setupV2(context)).rejects.toThrow("registration failed")
      expect(await bridgePort(45432)).toBeUndefined()
    }
  })
})

type ContextOptions = {
  registered: Array<{ name?: string }>
  location?: Plugin.Context["location"]
  transform?: (editor: { add(tool: { name?: string }): void }) => Promise<unknown>
}

function fakeContext(options: ContextOptions): Plugin.Context {
  const iterator = {
    next: () => new Promise<IteratorResult<never>>(() => {}),
    return: async () => ({ done: true, value: undefined }),
  }
  return {
    options: { notifications: { enabled: false }, serverURL: "http://127.0.0.1:45432" },
    location: options.location,
    session: { get: async () => ({ id: "session", projectID: "project", location: { directory: "/session" } }) },
    event: { subscribe: () => ({ [Symbol.asyncIterator]: () => iterator }) },
    tool: {
      transform: async (callback: (editor: { add(tool: { name?: string }): void }) => void) => {
        if (options.transform) return options.transform({ add: (tool) => options.registered.push(tool) }) as never
        callback({ add: (tool: { name?: string }) => options.registered.push(tool) })
        return { dispose: async () => {} }
      },
    },
  } as unknown as Plugin.Context
}

async function bridgePort(openCodePort: number): Promise<number | undefined> {
  for (let port = 4070; port <= 4090; port += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/openclient/v1/health`)
      const body = await response.json() as { openCodePort?: number; port?: number }
      if (body.openCodePort === openCodePort) return body.port ?? port
    } catch {
      // The bridge port scan intentionally skips unused listeners.
    }
  }
  return undefined
}
