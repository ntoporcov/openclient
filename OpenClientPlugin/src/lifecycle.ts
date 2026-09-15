import { startBridgeServer, type BridgeServer, type BridgeServerOptions } from "./server.js"

const stateKey = Symbol.for("@openclient/opencode-plugin/bridge")

type GlobalBridgeState = {
  serverPromise?: Promise<BridgeServer>
  leases: number
  openCodePort?: number
  stopping?: Promise<void>
}

type GlobalWithBridge = typeof globalThis & {
  [stateKey]?: GlobalBridgeState
}

export type BridgeLease = {
  server: BridgeServer
  release(): Promise<void>
}

export async function acquireBridge(options: BridgeServerOptions): Promise<BridgeLease> {
  const global = globalThis as GlobalWithBridge
  const state = global[stateKey] ?? { leases: 0 }
  global[stateKey] = state
  if (state.stopping) await state.stopping
  if (state.openCodePort !== undefined && state.openCodePort !== options.openCodePort) {
    throw new Error(`OpenClient bridge is already configured for OpenCode port ${state.openCodePort}`)
  }
  state.openCodePort = options.openCodePort
  state.serverPromise ??= Promise.resolve().then(() => startBridgeServer(options)).catch((error) => {
    state.serverPromise = undefined
    state.openCodePort = undefined
    throw error
  })

  const server = await state.serverPromise
  state.leases += 1
  let released = false
  return {
    server,
    async release() {
      if (released) return
      released = true
      state.leases = Math.max(0, state.leases - 1)
      if (state.leases !== 0 || state.serverPromise === undefined) return
      state.serverPromise = undefined
      state.stopping = server.stop().finally(() => {
        state.stopping = undefined
        state.openCodePort = undefined
      })
      await state.stopping
    },
  }
}
