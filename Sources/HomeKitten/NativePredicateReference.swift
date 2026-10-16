import Foundation

// Keep unrelated native clauses and comparison flags. Only replace object constants
// selected by a trusted in-process resolver; no raw predicates cross the bridge.
enum NativePredicateReference {
    struct Result { let predicate: NSPredicate; let changed: Bool }
    // Canonicalize redundant AND nesting only. HomeKit's characteristic factory
    // uses AND(identity,value) as one semantic leaf: keep that pair intact.
    // OR/NOT, native time/presence expressions and object constants are untouched.
    static func flattenConjunctions(_ value: NSPredicate) throws -> Result {
        guard let root = value as? NSCompoundPredicate, root.compoundPredicateType == .and,
              !isCharacteristicPair(root) else { return Result(predicate: value, changed: false) }
        var leaves: [NSPredicate] = []
        var changed = false
        func collect(_ predicate: NSPredicate, depth: Int) throws {
            guard depth <= 64, leaves.count < 256 else { throw failure("Native condition tree exceeds normalization limits") }
            if let compound = predicate as? NSCompoundPredicate, compound.compoundPredicateType == .and,
               !isCharacteristicPair(compound) {
                if depth > 0 { changed = true }
                guard !compound.subpredicates.isEmpty else { throw failure("Empty conjunction cannot be normalized here") }
                for child in compound.subpredicates {
                    guard let child = child as? NSPredicate else { throw failure("Unknown native condition child") }
                    try collect(child, depth: depth + 1)
                }
            } else { leaves.append(predicate) }
        }
        try collect(root, depth: 0)
        return Result(predicate: changed ? NSCompoundPredicate(andPredicateWithSubpredicates: leaves) : value, changed: changed)
    }

    private static func isCharacteristicPair(_ value: NSCompoundPredicate) -> Bool {
        guard value.compoundPredicateType == .and, value.subpredicates.count == 2 else { return false }
        let comparisons = value.subpredicates.compactMap { $0 as? NSComparisonPredicate }
        guard comparisons.count == 2 else { return false }
        let keys = comparisons.compactMap { $0.leftExpression.expressionType == .keyPath ? $0.leftExpression.keyPath : nil }
        return Set(keys) == Set(["characteristic", "characteristicValue"])
    }

    static func rewrite(_ value: NSPredicate, sourceIDs: Set<UUID>, resolver: (Any) -> Any?) throws -> Result {
        if let compound = value as? NSCompoundPredicate {
            let children = try compound.subpredicates.map { child -> Result in
                guard let predicate = child as? NSPredicate else { throw failure("Unknown native predicate child") }
                return try rewrite(predicate, sourceIDs: sourceIDs, resolver: resolver)
            }
            guard children.contains(where: \.changed) else { return Result(predicate: value, changed: false) }
            return Result(predicate: NSCompoundPredicate(type: compound.compoundPredicateType, subpredicates: children.map(\.predicate)), changed: true)
        }
        if let comparison = value as? NSComparisonPredicate {
            let left = try expression(comparison.leftExpression, sourceIDs: sourceIDs, resolver: resolver)
            let right = try expression(comparison.rightExpression, sourceIDs: sourceIDs, resolver: resolver)
            guard left.changed || right.changed else { return Result(predicate: value, changed: false) }
            guard comparison.predicateOperatorType != .customSelector else { throw failure("Custom selector predicate cannot be remapped safely") }
            return Result(predicate: NSComparisonPredicate(leftExpression: left.expression, rightExpression: right.expression,
                modifier: comparison.comparisonPredicateModifier, type: comparison.predicateOperatorType, options: comparison.options), changed: true)
        }
        guard !containsSource(value.predicateFormat, sourceIDs) else { throw failure("Unsupported native predicate references the source") }
        return Result(predicate: value, changed: false)
    }
    static func expression(_ value: NSExpression, sourceIDs: Set<UUID>, resolver: (Any) -> Any?) throws -> (expression: NSExpression, changed: Bool) {
        if value.expressionType == .constantValue {
            let result = try constant(value.constantValue as Any, sourceIDs: sourceIDs, resolver: resolver)
            return result.changed ? (NSExpression(forConstantValue: result.value), true) : (value, false)
        }
        guard !containsSource(value.description, sourceIDs) else { throw failure("Source reference inside unsupported expression") }
        return (value, false)
    }
    static func constant(_ value: Any, sourceIDs: Set<UUID>, resolver: (Any) -> Any?) throws -> (value: Any, changed: Bool) {
        if let replacement = resolver(value) { return (replacement, true) }
        if let values = value as? [Any] {
            let replaced = try values.map { try constant($0, sourceIDs: sourceIDs, resolver: resolver) }
            return (replaced.map(\.value), replaced.contains(where: \.changed))
        }
        if let values = value as? [String: Any] {
            var result = values; var changed = false
            for (key, original) in values {
                let replacement = try constant(original, sourceIDs: sourceIDs, resolver: resolver)
                result[key] = replacement.value; changed = changed || replacement.changed
            }
            return (result, changed)
        }
        if let values = value as? NSSet {
            let replaced = try values.allObjects.map { try constant($0, sourceIDs: sourceIDs, resolver: resolver) }
            return (NSSet(array: replaced.map(\.value)), replaced.contains(where: \.changed))
        }
        guard !containsSource(String(describing: value), sourceIDs) else { throw failure("Source UUID in unsupported constant; no approximation") }
        return (value, false)
    }
    private static func containsSource(_ text: String, _ ids: Set<UUID>) -> Bool {
        ids.contains { text.localizedCaseInsensitiveContains($0.uuidString) }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HomeKitten.NativePredicateReference", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
