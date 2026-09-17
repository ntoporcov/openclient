import Foundation

struct ComposerSuggestionSelection: Equatable {
    enum Kind: Equatable {
        case command
        case agent
    }

    struct Context: Equatable {
        let kind: Kind
        let query: String
        let ids: [String]
    }

    private var context: Context?
    private var selection: String?

    func selectedID(in context: Context?) -> String? {
        guard let context else { return nil }
        if self.context == context, let selection, context.ids.contains(selection) {
            return selection
        }
        return context.ids.first
    }

    mutating func reset(to context: Context?) {
        self.context = context
        selection = context?.ids.first
    }

    mutating func synchronize(to context: Context?) {
        // A key event may have already adopted the new query before SwiftUI renders it.
        guard self.context != context else { return }
        reset(to: context)
    }

    mutating func move(by offset: Int, in context: Context?) {
        guard let context,
              let selectedID = selectedID(in: context),
              let index = context.ids.firstIndex(of: selectedID) else {
            reset(to: context)
            return
        }
        let count = context.ids.count
        let nextIndex = (index + offset % count) % count
        self.context = context
        selection = context.ids[nextIndex < 0 ? nextIndex + count : nextIndex]
    }

    static func rankedCommands(_ commands: [OpenCodeCommand], query: String) -> [OpenCodeCommand] {
        commands.enumerated().compactMap { index, command -> (index: Int, command: OpenCodeCommand, rank: Int)? in
            guard query.isEmpty || command.name.localizedCaseInsensitiveContains(query) ||
                (command.description?.localizedCaseInsensitiveContains(query) ?? false) else {
                return nil
            }

            let rank: Int
            if query.isEmpty {
                rank = 0
            } else if command.name.localizedCaseInsensitiveCompare(query) == .orderedSame {
                rank = 0
            } else if command.name.range(of: query, options: [.caseInsensitive, .anchored], locale: .current) != nil {
                rank = 1
            } else {
                rank = 2
            }
            return (index, command, rank)
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let comparison = lhs.command.name.localizedCaseInsensitiveCompare(rhs.command.name)
            return comparison == .orderedSame ? lhs.index < rhs.index : comparison == .orderedAscending
        }
        .map(\.command)
    }
}
