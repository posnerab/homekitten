import Foundation

// Normalize only numeric 0/1 on a bool characteristic. Numeric formats retain
// their numeric type and all existing range/step/choice checks still apply.
enum AgentScalar {
    static func normalized(_ value: AgentValue, format: String?) -> AgentValue {
        if format == "bool", case .number(let number) = value, number == 0 || number == 1 {
            return .bool(number == 1)
        }
        return value
    }
}
