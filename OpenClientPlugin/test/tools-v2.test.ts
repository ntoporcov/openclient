import { describe, expect, test } from "bun:test"
import type { Plugin } from "@opencode/plugin"
import { registerV2Tools } from "../src/tools-v2.js"

describe("v2 OpenClient tools", () => {
  test("registers legacy schemas and the execution permission gate", async () => {
    const registered: Array<Record<string, unknown>> = []
    const context = fakeContext(registered)

    await registerV2Tools(context, {} as never, {} as never, {} as never)

    expect(registered.map((tool) => tool.name)).toEqual([
      "openclient_get_tool_list",
      "openclient_execute_tool",
    ])
    expect(registered[1]?.options).toEqual({ permission: "openclient_execute_tool" })
    expect(registered[0]?.output).toEqual({ type: "string" })
    expect(registered[1]?.output).toEqual({ type: "string" })

    const input = registered[1]?.input as { type: string; required: string[]; properties: Record<string, unknown> }
    expect(input.type).toBe("object")
    expect(input.required).toEqual(["client_id", "tool_id"])
    expect(input.properties.arguments).toMatchObject({ type: "object", default: {} })
  })

  test("does not use plugin location and maps session location, progress, and result metadata", async () => {
    const registered: Array<Record<string, unknown>> = []
    const progress: unknown[] = []
    const sessionCalls: unknown[] = []
    const context = fakeContext(registered, progress, sessionCalls)
    const bridge = {
      listTools: async (input: { sessionID: string; signal: AbortSignal }) => {
        expect(input.sessionID).toBe("session")
        return []
      },
    }

    await registerV2Tools(context, bridge as never, {} as never, {} as never)
    const execute = registered[0]?.execute as (input: unknown, context: unknown) => Promise<unknown>
    const result = await execute({}, {
      sessionID: "session",
      messageID: "message",
      agent: "agent",
      id: "call",
      signal: new AbortController().signal,
      progress: async (update: unknown) => { progress.push(update) },
    })

    expect(result).toEqual({
      output: '{\n  "clients": []\n}',
      content: '{\n  "clients": []\n}',
      metadata: { clientCount: 0, title: "OpenClient device tools" },
    })
    expect(sessionCalls).toEqual([{ sessionID: "session" }])
    expect(progress).toEqual([])
  })

  test("maps the v2 signal and session location into legacy execution", async () => {
    const registered: Array<Record<string, unknown>> = []
    const calls: unknown[] = []
    const progress: unknown[] = []
    const context = fakeContext(registered)
    const controller = new AbortController()
    const bridge = {
      validateExecution: () => ({ displayName: "Test iPhone" }),
      execute: async (input: unknown) => {
        calls.push(input)
        return { title: "Executed", output: "ok", metadata: { renderer: "test" } }
      },
    }

    await registerV2Tools(context, bridge as never, {} as never, {} as never)
    const execute = registered[1]?.execute as (input: unknown, context: unknown) => Promise<unknown>
    const result = await execute({
      client_id: "client",
      tool_id: "device_tool",
      arguments: { value: 1 },
    }, {
      sessionID: "session",
      messageID: "message",
      agent: "agent",
      id: "call",
      signal: controller.signal,
      progress: async (update: unknown) => { progress.push(update) },
    })

    expect(calls).toEqual([{
      clientID: "client",
      toolID: "device_tool",
      arguments: { value: 1 },
      context: {
        sessionID: "session",
        messageID: "message",
        agent: "agent",
        directory: "/session/location",
        worktree: "/session/location",
      },
      signal: controller.signal,
    }])
    expect(result).toEqual({
      output: "ok",
      content: "ok",
      metadata: { renderer: "test", title: "Executed" },
    })
    expect(progress).toEqual([{
      clientID: "client",
      title: "device_tool on Test iPhone",
      toolID: "device_tool",
    }])
  })

  test("checks cancellation before fetching session location", async () => {
    const registered: Array<Record<string, unknown>> = []
    const context = fakeContext(registered)
    await registerV2Tools(context, {} as never, {} as never, {} as never)
    const controller = new AbortController()
    controller.abort()

    const execute = registered[0]?.execute as (input: unknown, context: unknown) => Promise<unknown>
    await expect(execute({}, {
      sessionID: "session",
      messageID: "message",
      agent: "agent",
      id: "call",
      signal: controller.signal,
      progress: async () => {},
    })).rejects.toThrow("cancelled")
  })

  test("uses the registration lifetime when preview context has no signal", async () => {
    const registered: Array<Record<string, unknown>> = []
    const context = fakeContext(registered)
    const lifetime = new AbortController()
    await registerV2Tools(context, {} as never, {} as never, {} as never, lifetime.signal)

    const execute = registered[0]?.execute as (input: unknown, context: unknown) => Promise<unknown>
    const pending = execute({}, {
      sessionID: "session",
      messageID: "message",
      agent: "agent",
      id: "call",
      progress: async () => {},
    })
    lifetime.abort()
    await expect(pending).rejects.toThrow("cancelled")
  })
})

function fakeContext(registered: Array<Record<string, unknown>>, _progress: unknown[] = [], sessionCalls: unknown[] = []): Plugin.Context {
  const session = {
    get: async (input: unknown) => {
      sessionCalls.push(input)
      return { location: { directory: "/session/location" } }
    },
  }
  return {
    session,
    location: { directory: "/plugin/location" },
    tool: {
      transform: async (callback: (editor: { add: (tool: Record<string, unknown>) => void }) => void) => {
        callback({ add: (tool) => registered.push(tool) })
        return { dispose: async () => {} }
      },
    },
    permission: {},
    options: {},
    app: {},
    agent: {},
    aisdk: {},
    command: {},
    event: {},
    experimental: { terminal: {} },
    integration: {},
    mcp: {},
    model: {},
    generate: {},
    plugin: {},
    provider: {},
    reference: {},
    rpc: {},
    shell: {},
    skill: {},
    storage: {},
    vcs: {},
    websearch: {},
    worktree: {},
  } as unknown as Plugin.Context & { progress: unknown[] }
}
