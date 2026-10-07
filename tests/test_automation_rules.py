"""Exercise the production Swift serializer with Foundation predicates on macOS."""
import pathlib
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Foundation predicate APIs require macOS")
class AutomationRuleTests(unittest.TestCase):
    def test_predicates_components_and_unknown_values_remain_inspectable(self):
        source = pathlib.Path(__file__).parents[1] / "Sources/HomeKitten/AutomationRules.swift"
        fixture = r'''
import Foundation

let condition = NSCompoundPredicate(andPredicateWithSubpredicates: [
    NSPredicate(format: "shabbos == %@", NSNumber(value: false)),
    NSCompoundPredicate(orPredicateWithSubpredicates: [
        NSPredicate(format: "humidity >= 65"), NSPredicate(format: "ANY residents == 'home'")
    ])
])
let tree = AutomationRules.predicate(condition)
let children = tree["children"] as! [[String: Any]]
assert(tree["operator"] as! String == "and")
assert(children[0]["operator"] as! String == "equal")
assert((children[0]["left"] as! [String: Any])["keyPath"] as! String == "shabbos")
assert(((children[0]["right"] as! [String: Any])["value"] as! NSNumber).boolValue == false)
let either = children[1]["children"] as! [[String: Any]]
assert(either[0]["operator"] as! String == "greaterThanOrEqual")
assert(either[1]["modifier"] as! String == "any")
let offset = AutomationRules.components(DateComponents(timeZone: TimeZone(identifier: "America/Chicago"), hour: -1, minute: -18, weekday: 6))
assert(offset["hour"] as! Int == -1 && offset["minute"] as! Int == -18)
assert(offset["weekday"] as! Int == 6)
assert(offset["year"] == nil)
assert(offset["timeZone"] as! String == "America/Chicago")
let unknown = AutomationRules.value(NSObject()) as! [String: Any]
assert(unknown["supported"] as! Bool == false)
let range = AutomationRules.expression(NSExpression(forAggregate: [NSExpression(forConstantValue: 60), NSExpression(forConstantValue: 65)]))
assert((range["elements"] as! [[String: Any]]).count == 2)
let ref = NSObject()
let custom = AutomationRules.predicate(NSComparisonPredicate(leftExpression: NSExpression(forConstantValue: ref), rightExpression: NSExpression(forConstantValue: true), modifier: .direct, type: .equalTo, options: []), object: { value in
    value as AnyObject === ref ? ["kind": "characteristic", "id": "stable-id"] : nil
})
assert(((custom["left"] as! [String: Any])["value"] as! [String: Any])["id"] as! String == "stable-id")
let clock = AutomationRules.predicate(NSPredicate(format: "sunset <= now()"))
let function = clock["right"] as! [String: Any]
assert(function["kind"] as! String == "function")
assert(function["function"] as! String == "now")
assert((function["arguments"] as! [[String: Any]]).isEmpty)
let negated = AutomationRules.predicate(NSCompoundPredicate(notPredicateWithSubpredicate: condition))
assert(negated["operator"] as! String == "not")
let date = AutomationRules.value(Date(timeIntervalSince1970: 0)) as! [String: Any]
assert(date["iso8601"] as! String == "1970-01-01T00:00:00Z")
let exported: [String: Any] = ["predicate": tree, "offset": offset, "unknown": unknown, "range": range, "reference": custom, "negated": negated, "date": date, "noPredicate": NSNull(), "clock": clock]
assert(JSONSerialization.isValidJSONObject(exported))
let data = try JSONSerialization.data(withJSONObject: exported)
let decoded = try JSONSerialization.jsonObject(with: data)
assert(decoded is [String: Any])
print("Automation rule serialization passed")
'''
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            main = root / "main.swift"
            main.write_text(fixture)
            executable = root / "rules-test"
            build = subprocess.run(["xcrun", "swiftc", str(source), str(main), "-o", str(executable)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("serialization passed", run.stdout)
