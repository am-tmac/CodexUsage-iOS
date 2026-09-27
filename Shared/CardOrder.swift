import Foundation

/// Persisted order of the status-page cards, keyed by "provider:accountID" so a card keeps its
/// place across launches. Unknown keys (a newly added account) sort after the known ones in their
/// natural order — the list never loses or invents a card because the order file is stale.
enum CardOrder {
    private static let defaultsKey = "CodexUsage.cardOrder.v1"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
    static func save(_ order: [String]) { UserDefaults.standard.set(order, forKey: defaultsKey) }

    /// Moves `source` in front of `target`, returning the new order.
    static func move(_ source: String, before target: String, in keys: [String]) -> [String] {
        guard source != target,
              let from = keys.firstIndex(of: source),
              let to = keys.firstIndex(of: target) else { return keys }
        var updated = keys
        let item = updated.remove(at: from)
        // After removing the source, a target that sat after it has shifted one place left.
        updated.insert(item, at: from < to ? to - 1 : to)
        return updated
    }

    /// Applies a `List.onMove` offset pair (single item, SwiftUI's own semantics): the destination
    /// counts the dragged row's original slot, so it shifts back by one when moving downwards.
    static func move(_ source: Int, to destination: Int, in keys: [String]) -> [String] {
        var updated = keys
        guard updated.indices.contains(source) else { return keys }
        let item = updated.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        updated.insert(item, at: min(max(target, 0), updated.count))
        return updated
    }

    /// Applies a saved order to the live keys.
    static func sorted(_ keys: [String], by order: [String]) -> [String] {
        // A corrupt saved order (duplicate keys) keeps each key's first position instead of trapping.
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.enumerated().sorted { left, right in
            let a = rank[left.element] ?? (order.count + left.offset)
            let b = rank[right.element] ?? (order.count + right.offset)
            return a < b
        }.map(\.element)
    }
}
