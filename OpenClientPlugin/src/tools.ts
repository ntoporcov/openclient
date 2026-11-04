import { tool, type ToolContext } from "@opencode-ai/plugin"
import { createHash } from "node:crypto"
import { realpath } from "node:fs/promises"
import type { OpenClientBridge } from "./bridge.js"
import {
  executeDeclarativeTool,
  imageDeclarativeResult,
  isDeclarativeTool,
  normalizeImageArguments,
  normalizeVideoArguments,
  videoDeclarativeResult,
} from "./declarative.js"
import { type ImageResourceManager, imageToolID } from "./image.js"
import { isJsonObject } from "./protocol.js"
import { type VideoResourceManager, videoToolID } from "./video.js"
import type { RemoteDesktopSessions } from "./remote-desktop-session.js"

export function createOpenClientTools(
  bridge: OpenClientBridge,
  videoResources: VideoResourceManager,
  imageResources: ImageResourceManager,
  remoteDesktop?: RemoteDesktopSessions,
) {
  return {
    openclient_request_remote_access: tool({
      description: "Ask the user to complete a task on the host desktop, such as signing in. Shows an Open Remote Desktop card in OpenClient and waits for explicit Done or Cancel. Never request passwords in chat. Requires configured remote desktop access.",
      args: { reason: tool.schema.string().min(1).max(2000).describe("What the user needs to do on the desktop.") },
      async execute(args, context) {
        if (!remoteDesktop || !(await remoteDesktop.capability()).viewerAvailable) throw new Error("Remote desktop access is not configured or available on this host")
        const { request, result } = remoteDesktop.handoffs.request({
          reason: args.reason, sessionID: context.sessionID, messageID: context.messageID,
        }, context.abort)
        context.metadata({ title: "Your help is needed", metadata: { renderer: "openclient.remote-desktop", payload: request } })
        const outcome = await result
        return { title: "Remote desktop handoff", output: JSON.stringify({ outcome }),
          metadata: { renderer: "openclient.remote-desktop", payload: { ...request, outcome } } }
      },
    }),
    openclient_get_tool_list: tool({
      description: "Ask connected or recently disconnected OpenClient iOS apps for the tools they support. Tool availability is independent of which chat the app is displaying.",
      args: {
        client_id: tool.schema.string().optional().describe("Optional client ID used to query one connected OpenClient app."),
      },
      async execute(args, context) {
        const clients = await bridge.listTools({
          sessionID: context.sessionID,
          clientID: args.client_id,
          signal: context.abort,
        })
        return {
          title: "OpenClient device tools",
          output: JSON.stringify({ clients }, null, 2),
          metadata: { clientCount: clients.length },
        }
      },
    }),
    openclient_execute_tool: tool({
      description: "Execute a tool advertised by an OpenClient iOS app. Declarative visual tools remain available after that app disconnects; device actions require a live connection.",
      args: {
        client_id: tool.schema.string().describe("Client ID returned by openclient_get_tool_list."),
        tool_id: tool.schema.string().describe("Tool ID returned by openclient_get_tool_list."),
        arguments: tool.schema.record(tool.schema.string(), tool.schema.unknown()).default({}).describe("Arguments matching the device tool input schema."),
      },
      async execute(args, context) {
        if (!isJsonObject(args.arguments)) throw new Error("OpenClient tool arguments must contain JSON values")
        const declarative = isDeclarativeTool(args.tool_id)
        const videoInput = args.tool_id === videoToolID ? normalizeVideoArguments(args.arguments) : undefined
        const imageInput = args.tool_id === imageToolID ? normalizeImageArguments(args.arguments) : undefined
        const client = bridge.validateExecution(args.client_id, args.tool_id, context.sessionID, declarative)
        let canonicalMediaPath: string | undefined
        try {
          const mediaPath = videoInput?.filePath ?? imageInput?.filePath
          canonicalMediaPath = mediaPath === undefined ? undefined : await realpath(mediaPath)
        } catch {
          throw new Error(videoInput
            ? "Video filePath must reference a readable regular MP4 file"
            : "Image filePath must reference a readable regular JPEG, PNG, or WebP file")
        }
        await askForDeviceExecution(context, args.client_id, args.tool_id, canonicalMediaPath)
        context.metadata({
          title: `${args.tool_id} on ${client.displayName}`,
          metadata: {
            clientID: args.client_id,
            toolID: args.tool_id,
            ...(declarative ? { executionMode: "declarative" } : {}),
          },
        })
        if (declarative) {
          if (context.abort.aborted) throw new DOMException("OpenClient request cancelled", "AbortError")
          if (args.tool_id === videoToolID) {
            if (!videoInput) throw new Error("Video input was not validated")
            const payload = await videoResources.createResource({
              filePath: canonicalMediaPath ?? videoInput.filePath,
              ...(videoInput.title === undefined ? {} : { title: videoInput.title }),
              context: {
                clientID: args.client_id,
                sessionID: context.sessionID,
                messageID: context.messageID,
                agent: context.agent,
                directory: context.directory,
                worktree: context.worktree,
              },
            })
            if (context.abort.aborted) {
              await videoResources.removeResource(payload.resourceID)
              throw new DOMException("OpenClient request cancelled", "AbortError")
            }
            return videoDeclarativeResult(payload)
          }
          if (args.tool_id === imageToolID) {
            if (!imageInput) throw new Error("Image input was not validated")
            const payload = await imageResources.createResource({
              filePath: canonicalMediaPath ?? imageInput.filePath,
              ...(imageInput.title === undefined ? {} : { title: imageInput.title }),
              ...(imageInput.accessibilityLabel === undefined ? {} : { accessibilityLabel: imageInput.accessibilityLabel }),
              context: {
                clientID: args.client_id,
                sessionID: context.sessionID,
                messageID: context.messageID,
                agent: context.agent,
                directory: context.directory,
                worktree: context.worktree,
              },
            })
            if (context.abort.aborted) {
              await imageResources.removeResource(payload.resourceID)
              throw new DOMException("OpenClient request cancelled", "AbortError")
            }
            return imageDeclarativeResult(payload)
          }
          const result = executeDeclarativeTool(args.tool_id, args.arguments)
          if (!result) throw new Error(`Unknown declarative OpenClient tool: ${args.tool_id}`)
          return result
        }
        return bridge.execute({
          clientID: args.client_id,
          toolID: args.tool_id,
          arguments: args.arguments,
          context: {
            sessionID: context.sessionID,
            messageID: context.messageID,
            agent: context.agent,
            directory: context.directory,
            worktree: context.worktree,
          },
          signal: context.abort,
        })
      },
    }),
  }
}

async function askForDeviceExecution(
  context: ToolContext,
  clientID: string,
  toolID: string,
  filePath?: string,
): Promise<void> {
  const pathFingerprint = filePath === undefined
    ? undefined
    : createHash("sha256").update(filePath).digest("hex")
  const pattern = pathFingerprint === undefined
    ? `${clientID}/${toolID}`
    : `${clientID}/${toolID}/${pathFingerprint}`
  const permission = context.ask({
    permission: "openclient_execute_tool",
    patterns: [pattern],
    always: [pattern],
    metadata: { clientID, toolID, ...(filePath === undefined ? {} : { filePath }) },
  })
  if (!permission || typeof (permission as Promise<void>).then !== "function") {
    throw new Error("This OpenCode version does not support OpenClient device-tool permissions")
  }
  await permission
}
