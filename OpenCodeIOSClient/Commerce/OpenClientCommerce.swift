import Foundation
import Security
import StoreKit

enum OpenClientProductID {
    static let proLifetime = "com.ntoporcov.openclient.pro"
    static let proMonthly = "com.ntoporcov.openclient.pro.monthly.v1"

    static let proProducts: Set<String> = [proLifetime, proMonthly]

    static func grantsProAccess(_ productID: String) -> Bool {
        proProducts.contains(productID)
    }

    static func grantsProLifetimeAccess(_ productID: String) -> Bool {
        productID == proLifetime
    }
}

enum OpenClientProPurchaseOption: CaseIterable, Identifiable {
    case lifetime
    case monthly

    var id: String { productID }

    var productID: String {
        switch self {
        case .lifetime: OpenClientProductID.proLifetime
        case .monthly: OpenClientProductID.proMonthly
        }
    }
}

enum OpenClientCommerceLimits {
    static let dailyPromptLimit = 5
    static let freeSessionLimit = 1
}

enum OpenClientCommercePricing {
    static func isLifetimeLaunchPriceActive(
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let priceIncreaseDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 30
        )) else {
            return false
        }
        return date < priceIncreaseDate
    }
}

enum OpenClientPaywallReason: Identifiable, Equatable {
    case promptLimit
    case sessionLimit
    case actions
    case manual

    var id: String {
        switch self {
        case .promptLimit: "promptLimit"
        case .sessionLimit: "sessionLimit"
        case .actions: "actions"
        case .manual: "manual"
        }
    }

    var title: String {
        switch self {
        case .promptLimit: String(localized: "Daily Prompt Limit Reached")
        case .sessionLimit: String(localized: "Create Unlimited Sessions")
        case .actions: String(localized: "Unlock Actions")
        case .manual: String(localized: "OpenClient Pro")
        }
    }

    var message: String {
        switch self {
        case .promptLimit:
            String(localized: "Upgrade to send unlimited prompts and support continued development of the open-source app.")
        case .sessionLimit:
            String(localized: "Free users can create one session. Upgrade for unlimited sessions and prompts.")
        case .actions:
            String(localized: "Actions run project commands in temporary sessions and only surface when they need your attention.")
        case .manual:
            String(localized: "Unlock unlimited prompts and sessions, plus support the signed App Store build.")
        }
    }
}

struct OpenClientUsageMeter: Codable, Equatable {
    var promptDay: String
    var dailyPromptCount: Int
    var createdSessionCount: Int

    static let empty = OpenClientUsageMeter(promptDay: Self.dayString(for: Date()), dailyPromptCount: 0, createdSessionCount: 0)

    mutating func normalize(for date: Date = Date()) {
        let currentDay = Self.dayString(for: date)
        if promptDay != currentDay {
            promptDay = currentDay
            dailyPromptCount = 0
        }
    }

    static func dayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

protocol OpenClientUsagePersisting {
    func load() -> OpenClientUsageMeter
    func save(_ meter: OpenClientUsageMeter)
}

struct OpenClientUsageStore: OpenClientUsagePersisting {
    private let service = "com.ntoporcov.openclient.usage-meter"
    private let account = "default"

    func load() -> OpenClientUsageMeter {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              var meter = try? JSONDecoder().decode(OpenClientUsageMeter.self, from: data) else {
            return .empty
        }
        meter.normalize()
        return meter
    }

    func save(_ meter: OpenClientUsageMeter) {
        guard let data = try? JSONEncoder().encode(meter) else { return }
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        SecItemDelete(baseQuery as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

#if DEBUG
enum OpenClientDebugEntitlementOverride: String, CaseIterable, Identifiable {
    case system
    case free
    case monthly
    case unlocked
    case limitReached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .free: String(localized: "Free")
        case .monthly: String(localized: "Monthly")
        case .unlocked: String(localized: "Unlocked")
        case .limitReached: String(localized: "Limit Reached")
        }
    }
}
#endif

@MainActor
final class OpenClientPurchaseManager: ObservableObject {
    @Published private(set) var proLifetimeProduct: Product?
    @Published private(set) var proMonthlyProduct: Product?
    @Published private(set) var hasProUnlock = false
    @Published private(set) var hasProLifetimeUnlock = false
    @Published private(set) var hasProMonthlyUnlock = false
    @Published private(set) var hasRefreshedEntitlements = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var isRestoringPurchases = false
    @Published private(set) var purchaseError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = observeTransactions()
        Task {
            await refreshProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func refreshProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: OpenClientProductID.proProducts)
            proLifetimeProduct = products.first { $0.id == OpenClientProductID.proLifetime }
            proMonthlyProduct = products.first { $0.id == OpenClientProductID.proMonthly }
            purchaseError = nil
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func product(for option: OpenClientProPurchaseOption) -> Product? {
        switch option {
        case .lifetime: proLifetimeProduct
        case .monthly: proMonthlyProduct
        }
    }

    func purchasePro(_ option: OpenClientProPurchaseOption) async {
        guard hasRefreshedEntitlements,
              purchasingProductID == nil,
              !isRestoringPurchases,
              !isLoadingProducts else { return }
        purchasingProductID = option.productID
        defer { purchasingProductID = nil }

        if product(for: option) == nil {
            await refreshProducts()
        }

        guard let product = product(for: option) else {
            purchaseError = String(localized: "OpenClient Pro is not available yet.")
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await refreshEntitlements()
                await transaction.finish()
                purchaseError = nil
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        guard hasRefreshedEntitlements,
              purchasingProductID == nil,
              !isRestoringPurchases,
              !isLoadingProducts else { return }
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseError = nil
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        var lifetimeUnlocked = false
        var monthlyUnlocked = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if OpenClientProductID.grantsProAccess(transaction.productID), transaction.revocationDate == nil {
                unlocked = true
                lifetimeUnlocked = lifetimeUnlocked || OpenClientProductID.grantsProLifetimeAccess(transaction.productID)
                monthlyUnlocked = monthlyUnlocked || transaction.productID == OpenClientProductID.proMonthly
            }
        }
        hasProUnlock = unlocked
        hasProLifetimeUnlock = lifetimeUnlocked
        hasProMonthlyUnlock = monthlyUnlocked
        hasRefreshedEntitlements = true
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.checkVerified(result) {
                    await self.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let signedType):
            return signedType
        case .unverified:
            throw StoreKitError.notAvailableInStorefront
        }
    }
}
