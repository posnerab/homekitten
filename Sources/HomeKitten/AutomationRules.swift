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
