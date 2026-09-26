import type { Plugin } from "@opencode/plugin"
import type { ToolContext as V2ToolContext, Result as V2Result } from "@opencode/plugin/promise/tool"
import type { Registration } from "@opencode/plugin/promise/registration"
import type { ToolContext as V1ToolContext } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"
import { createOpenClientTools } from "./tools.js"
import type { OpenClientBridge } from "./bridge.js"
import type { ImageResourceManager } from "./image.js"
import type { VideoResourceManager } from "./video.js"

const executionPermission = "openclient_execute_tool"

export async function registerV2Tools(
  ctx: Plugin.Context,
  bridge: OpenClientBridge,
  videoResources: VideoResourceManager,
  imageResources: ImageResourceManager,
  lifetimeSignal = new AbortController().signal,
): Promise<Registration> {
  const legacy = createOpenClientTools(bridge, videoResources, imageResources)

  return ctx.tool.transform((editor) => {
    editor.add({
      name: "openclient_get_tool_list",
      description: legacy.openclient_get_tool_list.description,
      input: toolSchema(legacy.openclient_get_tool_list.args),
      output: { type: "string" },
      execute: (input, context) => executeLegacy(
        legacy.openclient_get_tool_list,
        input,
        context,
        ctx,
        lifetimeSignal,
      ),
    })
    editor.add({
      name: "openclient_execute_tool",
      description: legacy.openclient_execute_tool.description,
      input: toolSchema(legacy.openclient_execute_tool.args),
      output: { type: "string" },
      options: { permission: executionPermission },
      execute: (input, context) => executeLegacy(
        legacy.openclient_execute_tool,
        input,
        context,
        ctx,
        lifetimeSignal,
      ),
    })
  })
}

function toolSchema(args: Record<string, unknown>) {
  // JSON Schema is supported by both the early v2 preview and current hosts;
  // older hosts cannot introspect Zod's Standard Schema implementation.
  return tool.schema.toJSONSchema(tool.schema.object(args), { io: "input" })
}

async function executeLegacy(
  definition: {
    args: Record<string, unknown>
    execute: (input: never, context: V1ToolContext) => Promise<unknown>
  },
  input: unknown,
  context: V2ToolContext,
  plugin: Plugin.Context,
  lifetimeSignal: AbortSignal,
): Promise<V2Result> {
  // Early v2 previews omit per-tool cancellation; plugin disposal still cancels
  // outstanding device operations. Current v2 also cancels on session interrupt.
  const signal = context.signal ? AbortSignal.any([context.signal, lifetimeSignal]) : lifetimeSignal
  throwIfAborted(signal)
  const session = await plugin.session.get({ sessionID: context.sessionID })
  throwIfAborted(signal)

  const progress: Promise<void>[] = []
  const legacyContext: V1ToolContext = {
    sessionID: context.sessionID,
    messageID: context.messageID,
    agent: context.agent,
    directory: session.location.directory,
    worktree: session.location.directory,
    abort: signal,
    metadata(update) {
      const metadata = {
        ...(update.metadata ?? {}),
        ...(update.title === undefined ? {} : { title: update.title }),
      }
      const pending = context.progress(metadata)
      progress.push(pending)
      // Observe rejection immediately; propagate it below without an unhandled promise.
      void pending.catch(() => {})
    },
    async ask() {
      // V2 evaluates the declared permission before entering execute. This keeps the
      // legacy implementation's post-guard ask call compatible without a permissive path.
    },
  }

  const parsed = tool.schema.object(definition.args).parse(input)
  const result = await definition.execute(parsed as never, legacyContext)
  throwIfAborted(signal)
  await Promise.all(progress)
  return toV2Result(result)
}

function toV2Result(result: unknown): V2Result {
  if (typeof result === "string") return { output: result, content: result }
  if (!result || typeof result !== "object") return { output: String(result), content: String(result) }

  const value = result as {
    title?: string
    output?: string
    metadata?: Record<string, unknown>
    attachments?: ReadonlyArray<{ mime: string; url: string; filename?: string }>
  }
  const metadata = {
    ...(value.metadata ?? {}),
    ...(value.title === undefined ? {} : { title: value.title }),
  }
  // Also declare structured output so v2 Code Mode receives the value, rather
  // than null when it forwards only result.output from a tool invocation.
  if (!value.attachments?.length) return { output: value.output ?? "", content: value.output ?? "", ...(Object.keys(metadata).length ? { metadata } : {}) }
  return {
    output: value.output ?? "",
    content: [
      { type: "text", text: value.output ?? "" },
      ...value.attachments.map((attachment) => ({
        type: "file" as const,
        uri: attachment.url,
        mime: attachment.mime,
        ...(attachment.filename === undefined ? {} : { name: attachment.filename }),
      })),
    ],
    ...(Object.keys(metadata).length ? { metadata } : {}),
  }
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw new DOMException("OpenClient request cancelled", "AbortError")
}
