import Foundation

// Inspect references without evaluating predicates or changing native clauses.
enum BridgeRemovalAudit {
    static func validateIDs(_ supplied: [UUID], actual: Set<UUID>, nonempty: Bool, label: String) throws {
        guard supplied.count <= 512, Set(supplied).count == supplied.count,
              !nonempty || !supplied.isEmpty, Set(supplied) == actual else {
            throw failure("\(label) changed or UUID list is incomplete/ambiguous")
        }
    }

    static func predicateUses(_ value: NSPredicate, ids: Set<UUID>, matches: (Any) -> Bool) throws -> Bool {
        if let compound = value as? NSCompoundPredicate {
            for child in compound.subpredicates {
                guard let predicate = child as? NSPredicate else { throw failure("Unknown native predicate child") }
                if try predicateUses(predicate, ids: ids, matches: matches) { return true }
            }
            return false
        }
        if let comparison = value as? NSComparisonPredicate {
            return try expressionUses(comparison.leftExpression, ids: ids, matches: matches)
                || expressionUses(comparison.rightExpression, ids: ids, matches: matches)
        }
        if ["TRUEPREDICATE", "FALSEPREDICATE"].contains(value.predicateFormat) { return false }
        throw failure("Unsupported native predicate; bridge references cannot be certified")
    }

    static func expressionUses(_ value: NSExpression, ids: Set<UUID>, matches: (Any) -> Bool) throws -> Bool {
        if containsID(value.description, ids: ids) { return true }
        switch value.expressionType {
        case .constantValue: return try constantUses(value.constantValue as Any, ids: ids, matches: matches)
        case .evaluatedObject, .keyPath, .variable: return false
        case .function:
            if try expressionUses(value.operand, ids: ids, matches: matches) { return true }
            for argument in value.arguments ?? [] {
                if try expressionUses(argument, ids: ids, matches: matches) { return true }
            }
            return false
        case .aggregate: return try constantUses(value.collection, ids: ids, matches: matches)
        case .unionSet, .intersectSet, .minusSet:
            return try expressionUses(value.left, ids: ids, matches: matches)
                || expressionUses(value.right, ids: ids, matches: matches)
        case .subquery:
            return try constantUses(value.collection, ids: ids, matches: matches)
                || predicateUses(value.predicate, ids: ids, matches: matches)
        case .conditional:
            return try predicateUses(value.predicate, ids: ids, matches: matches)
                || expressionUses(value.true, ids: ids, matches: matches)
                || expressionUses(value.false, ids: ids, matches: matches)
        default: throw failure("Unsupported native expression; bridge references cannot be certified")
        }
    }

    private static func constantUses(_ value: Any, ids: Set<UUID>, matches: (Any) -> Bool) throws -> Bool {
        if matches(value) || containsID(String(describing: value), ids: ids) { return true }
        if let expression = value as? NSExpression { return try expressionUses(expression, ids: ids, matches: matches) }
        if let values = value as? [Any] {
            for child in values { if try constantUses(child, ids: ids, matches: matches) { return true } }
        } else if let values = value as? [String: Any] {
            for (key, child) in values {
                if containsID(key, ids: ids) { return true }
                if try constantUses(child, ids: ids, matches: matches) { return true }
            }
        } else if let values = value as? NSSet {
            return try constantUses(values.allObjects, ids: ids, matches: matches)
        } else if let values = value as? NSOrderedSet {
            return try constantUses(values.array, ids: ids, matches: matches)
        }
        return false
    }

    private static func containsID(_ text: String, ids: Set<UUID>) -> Bool {
        ids.contains { text.localizedCaseInsensitiveContains($0.uuidString) }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HomeKitten.BridgeRemovalAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
