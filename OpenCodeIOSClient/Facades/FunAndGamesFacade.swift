import Combine
import Foundation

@MainActor
final class FunAndGamesFacade: ObservableObject {
    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        viewModel.bindFunAndGamesScope()
        Publishers.MergeMany([
            viewModel.funAndGamesStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.projectStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.$backendConnection.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingFindPlaceModelSheet.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingFindBugLanguageSheet.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingFindBugModelSheet.map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)
    }

    var showsSection: Bool {
        viewModel.allowsFunAndGames && viewModel.funAndGamesPreferences.showsSection
    }
    var sortedProviders: [OpenCodeProvider] { viewModel.sortedProviders }
    var isLoading: Bool { viewModel.isLoading }
    var pendingFindBugLanguage: FindBugGameLanguage? { viewModel.pendingFindBugLanguage }

    func setupPhase(for sessionID: String) -> FunAndGamesSetup.Phase? {
        viewModel.funAndGamesStore.setupPhase(for: sessionID)
    }

    func hasPendingSetup(for sessionID: String) -> Bool {
        viewModel.funAndGamesStore.hasPendingSetup(for: sessionID)
    }

    /// Read-only recovery for refresh/reconnect. Never creates a session or submits another turn.
    func reconcileSetup(for sessionID: String) async {
        guard let connection = viewModel.backendConnection else { return }
        let owner = viewModel.funAndGamesOwner
        guard let setup = viewModel.funAndGamesStore.setup(for: sessionID),
              setup.phase == .uncertain || setup.phase == .submitting else { return }
        _ = try? await FunAndGamesCoordinator(store: viewModel.funAndGamesStore).reconcile(setup,
            owner: owner, connection: connection, isCurrent: { [weak viewModel] in
                viewModel?.isCurrentBackendConnection(connection) == true && viewModel?.funAndGamesOwner == owner
            })
    }

    var isShowingFindPlaceModelSheet: Bool {
        get { viewModel.allowsFunAndGames && viewModel.isShowingFindPlaceModelSheet }
        set { viewModel.isShowingFindPlaceModelSheet = newValue && viewModel.allowsFunAndGames }
    }

    var isShowingFindBugLanguageSheet: Bool {
        get { viewModel.allowsFunAndGames && viewModel.isShowingFindBugLanguageSheet }
        set { viewModel.isShowingFindBugLanguageSheet = newValue && viewModel.allowsFunAndGames }
    }

    var isShowingFindBugModelSheet: Bool {
        get { viewModel.allowsFunAndGames && viewModel.isShowingFindBugModelSheet }
        set { viewModel.isShowingFindBugModelSheet = newValue && viewModel.allowsFunAndGames }
    }

    func presentFindPlaceModelSheet() { viewModel.presentFindPlaceModelSheet() }
    func presentFindBugLanguageSheet() { viewModel.presentFindBugLanguageSheet() }
    func selectFindBugLanguage(_ language: FindBugGameLanguage) { viewModel.selectFindBugLanguage(language) }
    func startFindPlaceGame(model: OpenCodeModelReference) async {
        guard viewModel.allowsFunAndGames else { return }
        await viewModel.startFindPlaceGame(model: model)
    }
    func startFindBugGame(model: OpenCodeModelReference) async {
        guard viewModel.allowsFunAndGames else { return }
        await viewModel.startFindBugGame(model: model)
    }
    func cancelFindBugModelSelection() {
        viewModel.isShowingFindBugModelSheet = false
        viewModel.pendingFindBugLanguage = nil
    }
}
