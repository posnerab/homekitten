import Foundation

// Configuration serialization only: never evaluate HomeKit predicates against cached values.
enum AutomationRules {
    static func components(_ value: DateComponents) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, number) in [("era", value.era), ("year", value.year), ("month", value.month),
                              ("day", value.day), ("hour", value.hour), ("minute", value.minute),
                              ("second", value.second), ("nanosecond", value.nanosecond),
                              ("weekday", value.weekday), ("weekdayOrdinal", value.weekdayOrdinal),
                              ("quarter", value.quarter), ("weekOfMonth", value.weekOfMonth),
                              ("weekOfYear", value.weekOfYear), ("yearForWeekOfYear", value.yearForWeekOfYear)] {
            if let number { result[key] = number }
        }
        if let zone = value.timeZone { result["timeZone"] = zone.identifier }
        if let calendar = value.calendar {
            result["calendar"] = String(describing: calendar.identifier)
            result["calendarTimeZone"] = calendar.timeZone.identifier
        }
        if let leap = value.isLeapMonth { result["isLeapMonth"] = leap }
        return result
    }

    static func value(_ value: Any?, object: (Any) -> [String: Any]? = { _ in nil }) -> Any {
        guard let value else { return NSNull() }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number : ["supported": false, "kind": "nonFiniteNumber"]
        }
        if let string = value as? String { return string }
        if let date = value as? Date { return ["kind": "date", "iso8601": ISO8601DateFormatter().string(from: date)] }
        if let date = value as? DateComponents { return ["kind": "dateComponents", "components": components(date)] }
        if let id = value as? UUID { return ["kind": "uuid", "id": id.uuidString] }
        if let values = value as? [Any] { return values.map { self.value($0, object: object) } }
        if let values = value as? Set<AnyHashable> {
            return ["kind": "set", "values": values.map { self.value($0, object: object) }]
        }
        if let values = value as? [String: Any] { return values.mapValues { self.value($0, object: object) } }
        if value is NSNull { return NSNull() }
        if let result = object(value) { return result }
        return ["kind": String(describing: type(of: value)), "supported": false]
    }

    static func predicate(_ predicate: NSPredicate, object: (Any) -> [String: Any]? = { _ in nil }) -> [String: Any] {
        var result: [String: Any] = ["format": predicate.predicateFormat]
        if let compound = predicate as? NSCompoundPredicate {
            result["kind"] = "compound"
            result["operator"] = ["not", "and", "or"][Int(compound.compoundPredicateType.rawValue)]
            result["children"] = compound.subpredicates.map { child -> [String: Any] in
                guard let child = child as? NSPredicate else { return ["supported": false] }
                return self.predicate(child, object: object)
            }
        } else if let comparison = predicate as? NSComparisonPredicate {
            result["kind"] = "comparison"
            result["operatorRawValue"] = comparison.predicateOperatorType.rawValue
            result["operator"] = comparisonOperator(comparison.predicateOperatorType)
            result["modifierRawValue"] = comparison.comparisonPredicateModifier.rawValue
            result["modifier"] = ["direct", "all", "any"][Int(comparison.comparisonPredicateModifier.rawValue)]
            result["optionsRawValue"] = comparison.options.rawValue
            result["left"] = expression(comparison.leftExpression, object: object)
            result["right"] = expression(comparison.rightExpression, object: object)
        } else {
            result["kind"] = String(describing: type(of: predicate))
            result["supported"] = false
        }
        return result
    }

    static func expression(_ expression: NSExpression, object: (Any) -> [String: Any]? = { _ in nil }) -> [String: Any] {
        var result: [String: Any] = ["typeRawValue": expression.expressionType.rawValue]
        switch expression.expressionType {
        case .constantValue:
            result["kind"] = "constant"
            result["value"] = value(expression.constantValue, object: object)
        case .keyPath:
            result["kind"] = "keyPath"; result["keyPath"] = expression.keyPath
        case .variable:
            result["kind"] = "variable"; result["variable"] = expression.variable
        case .evaluatedObject:
            result["kind"] = "evaluatedObject"
        case .function:
            result["kind"] = "function"; result["function"] = expression.function
            result["operand"] = self.expression(expression.operand, object: object)
            result["arguments"] = (expression.arguments ?? []).map { self.expression($0, object: object) }
        case .aggregate:
            result["kind"] = "aggregate"
            result["elements"] = (expression.collection as? [NSExpression])?.map { self.expression($0, object: object) } ?? []
        default:
            result["kind"] = "unsupportedExpression"; result["supported"] = false
        }
        return result
    }

    private static func comparisonOperator(_ type: NSComparisonPredicate.Operator) -> String {
        switch type {
        case .lessThan: "lessThan"
        case .lessThanOrEqualTo: "lessThanOrEqual"
        case .greaterThan: "greaterThan"
        case .greaterThanOrEqualTo: "greaterThanOrEqual"
        case .equalTo: "equal"
        case .notEqualTo: "notEqual"
        case .matches: "matches"
        case .like: "like"
        case .beginsWith: "beginsWith"
        case .endsWith: "endsWith"
        case .in: "in"
        case .contains: "contains"
        case .between: "between"
        case .customSelector: "customSelector"
        @unknown default: "unknown"
        }
    }
}

extension AutomationRules {
    // Pair only direct siblings in an exact HomeKit factory predicate. Never borrow a
    // value from a different AND/OR branch or infer an absent comparison.
    static func characteristicPair(_ node: [String: Any]) -> (reference: [String: Any], comparison: [String: Any])? {
        guard node["kind"] as? String == "compound", node["operator"] as? String == "and",
              let children = node["children"] as? [[String: Any]], children.count == 2,
              let identity = children.first(where: { ($0["left"] as? [String: Any])?["keyPath"] as? String == "characteristic" }),
              let comparison = children.first(where: { ($0["left"] as? [String: Any])?["keyPath"] as? String == "characteristicValue" }),
              identity["operator"] as? String == "equal",
              [identity, comparison].allSatisfy({ $0["kind"] as? String == "comparison" && $0["modifier"] as? String == "direct" && ($0["optionsRawValue"] as? NSNumber)?.uintValue == 0 && ($0["right"] as? [String: Any])?["kind"] as? String == "constant" }),
              let ref = (identity["right"] as? [String: Any])?["value"] as? [String: Any],
              (ref["kind"] as? String == "characteristic" && ref["id"] as? String != nil) ||
                (ref["kAccessoryUUID"] as? String != nil && ref["kServiceInstanceID"] as? NSNumber != nil && ref["kCharacteristicInstanceID"] as? NSNumber != nil) else { return nil }
        return (ref, comparison)
    }

    static func conditionSummary(_ node: [String: Any]) -> String {
        if let pair = characteristicPair(node) {
            let ref = pair.reference, comparison = pair.comparison
            let name = [ref["accessoryName"] as? String, ref["name"] as? String].compactMap { $0 }.joined(separator: " · ")
            let operators = ["equal": "is", "notEqual": "is not", "lessThan": "is less than", "greaterThan": "is greater than", "lessThanOrEqual": "is at most", "greaterThanOrEqual": "is at least"]
            let value = (comparison["right"] as? [String: Any])?["value"]
            var display = value.map { String(describing: $0) } ?? "missing value"
            if (ref["type"] as? String)?.hasPrefix("00000025-") == true, let number = value as? NSNumber,
               number == 0 || number == 1 { display = number.boolValue ? "on" : "off" }
            let label = name.isEmpty ? ref["id"] as? String ?? "Unavailable accessory [\(ref["kAccessoryUUID"] as? String ?? "unknown UUID")]" : name
            return "\(label) \(operators[comparison["operator"] as? String ?? ""] ?? comparison["operator"] as? String ?? "compares") \(display)"
        }
        if node["kind"] as? String == "compound", let children = node["children"] as? [[String: Any]] {
            let summaries = children.map { conditionSummary($0) }
            switch node["operator"] as? String {
            case "and": return summaries.map { "(\($0))" }.joined(separator: " AND ")
            case "or": return summaries.map { "(\($0))" }.joined(separator: " OR ")
            case "not": return "NOT (\(summaries.joined(separator: ", ")))"
            default: break
            }
        }
        if (node["left"] as? [String: Any])?["keyPath"] as? String == "characteristic" {
            let ref = (node["right"] as? [String: Any])?["value"] as? [String: Any]
            let name = ref?["accessoryName"] as? String ?? ref?["id"] as? String ?? "Unresolved accessory"
            return "\(name): accessory reference without a value comparison"
        }
        // Native time/presence and unknown clauses remain inspectable, with their exact format.
        return node["format"] as? String ?? "Unsupported condition (retained)"
    }

    static func conditionIssues(_ node: [String: Any], path: String = "predicate") -> [[String: Any]] {
        if let pair = characteristicPair(node) {
            if pair.reference["kind"] as? String == "characteristic" { return [] }
            return [["code": "unresolvedAccessoryReference", "path": path, "message": "Saved accessory reference is unavailable; explicit UUID mapping is required", "reference": pair.reference, "format": node["format"] ?? ""]]
        }
        if let children = node["children"] as? [[String: Any]] {
            return children.enumerated().flatMap { conditionIssues($0.element, path: "\(path).children[\($0.offset)]") }
        }
        if (node["left"] as? [String: Any])?["keyPath"] as? String == "characteristic" {
            return [["code": "unpairedCharacteristicReference", "path": path, "message": conditionSummary(node), "format": node["format"] ?? ""]]
        }
        if (node["left"] as? [String: Any])?["keyPath"] as? String == "characteristicValue" {
            return [["code": "unpairedCharacteristicValue", "path": path, "message": "Value comparison has no unambiguous accessory reference", "format": node["format"] ?? ""]]
        }
        if node["supported"] as? Bool == false {
            return [["code": "unsupportedPredicate", "path": path, "message": "Native condition retained but not understood", "format": node["format"] ?? ""]]
        }
        return []
    }
}

// A readable JSON value tree for complete native backups. Optional new fields keep
// old backups decodable; unknown public-API data is retained without lossy coercion.
indirect enum BackupJSON: Codable, Sendable {
    case object([String: BackupJSON]), array([BackupJSON]), string(String), number(Decimal), bool(Bool), null
    init(object: Any) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: BackupJSON].self) { self = .object(v) }
        else if let v = try? c.decode([BackupJSON].self) { self = .array(v) }
        else { self = .number(try c.decode(Decimal.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
