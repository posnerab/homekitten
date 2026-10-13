import Foundation

enum AgentMembership {
    static func desired(_ existing: [UUID], replacement: [UUID]?, additions: [UUID]?, removals: [UUID]?) throws -> Set<UUID> {
        guard replacement == nil || (additions == nil && removals == nil) else { throw failure("Replacement and incremental membership are mutually exclusive") }
        for values in [replacement, additions, removals].compactMap({ $0 }) {
            guard values.count <= 512, Set(values).count == values.count else { throw failure("Membership requires unique UUIDs (maximum 512)") }
        }
        let added = Set(additions ?? []), removed = Set(removals ?? [])
        guard added.isDisjoint(with: removed), removed.isSubset(of: Set(existing)) else { throw failure("Removal must identify current members and cannot overlap additions") }
        return replacement.map(Set.init) ?? Set(existing).union(added).subtracting(removed)
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HomeKitten.AgentMembership", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
