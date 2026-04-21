import SwiftUI

struct ConnectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            if viewModel.showSavedServerPrompt, viewModel.hasSavedServer {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Reconnect to last server?")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.config.trimmedBaseURL)
                            Text(viewModel.config.username)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)

                        HStack(spacing: 12) {
                            Button("Reconnect") {
                                Task { await viewModel.reconnectToSavedServer() }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Edit Details") {
                                viewModel.dismissSavedServerPrompt()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Server") {
                TextField("Base URL", text: $viewModel.config.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("connection.baseURL")

                TextField("Username", text: $viewModel.config.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.username")

                SecureField("Password", text: $viewModel.config.password)
                    .accessibilityIdentifier("connection.password")
            }

            Section {
                Button(viewModel.isLoading ? "Connecting..." : "Connect to OpenCode") {
                    Task { await viewModel.connect() }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("connection.connect")
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.large)
    }
}
