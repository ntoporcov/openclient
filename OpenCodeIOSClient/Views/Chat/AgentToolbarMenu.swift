import SwiftUI

struct AgentToolbarMenu: View {
    @ObservedObject var viewModel: AppViewModel
    let session: OpenCodeSession
    let glassNamespace: Namespace.ID

    var body: some View {
        Menu {
            ForEach(viewModel.selectableAgents) { agent in
                Button(agent.name) {
                    viewModel.selectAgent(named: agent.name, for: session)
                }
            }
        } label: {
            Text(viewModel.agentToolbarTitle(for: session).capitalized)
                .font(.caption)
                .opencodeToolbarGlassID("agent-toolbar", in: glassNamespace)
        }
    }
}
