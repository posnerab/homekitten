import pathlib
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Production Swift helper validation needs macOS')
class NativeMigrationTests(unittest.TestCase):
    def test_native_predicates_boolean_targets_and_membership_guards(self):
        source=pathlib.Path(__file__).parents[1]/'Sources/HomeKitten'
        enum=(source/'AgentBridge.swift').read_text().split('enum AgentValue:')[1].split('struct AgentReadRequest:')[0]
        fixture=r'''
import Foundation
final class Reference: NSObject {
    let id: UUID
    init(_ id: UUID) { self.id = id }
    override var description: String { id.uuidString }
}
let id = UUID(), unrelatedID = UUID()
let original = Reference(id), replacement = Reference(UUID()), unrelated = Reference(unrelatedID)
let sourceIDs: Set<UUID> = [id]
func resolve(_ value: Any) -> Any? { (value as? Reference) === original ? replacement : nil }
let identity = NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: "characteristic"), rightExpression: NSExpression(forConstantValue: original), modifier: .direct, type: .equalTo, options: [.caseInsensitive, .diacriticInsensitive])
let value = NSPredicate(format: "characteristicValue == 0")
let time = NSPredicate(format: "sunset <= now()")
let customPresence = NSComparisonPredicate(leftExpression: NSExpression(forConstantValue: unrelated), rightExpression: NSExpression(forConstantValue: true), modifier: .any, type: .notEqualTo, options: [])
let sourceClause = NSCompoundPredicate(andPredicateWithSubpredicates: [identity, value])
let guarded = NSCompoundPredicate(orPredicateWithSubpredicates: [sourceClause, time, customPresence])
let result = try NativePredicateReference.rewrite(guarded, sourceIDs: sourceIDs, resolver: resolve)
assert(result.changed)
let compound = result.predicate as! NSCompoundPredicate
assert(compound.compoundPredicateType == .or)
assert(compound.subpredicates[1] as AnyObject === time)
assert(compound.subpredicates[2] as AnyObject === customPresence)
let replacedClause = compound.subpredicates[0] as! NSCompoundPredicate
assert(replacedClause.subpredicates[1] as AnyObject === value)
let comparison = replacedClause.subpredicates[0] as! NSComparisonPredicate
assert(comparison.rightExpression.constantValue as AnyObject === replacement)
assert(comparison.options == identity.options)
assert(comparison.comparisonPredicateModifier == identity.comparisonPredicateModifier)
assert(comparison.predicateOperatorType == identity.predicateOperatorType)
let untouched = try NativePredicateReference.rewrite(time, sourceIDs: sourceIDs, resolver: resolve)
assert(!untouched.changed && untouched.predicate === time)
let opaque = NSExpression(forVariable: "source_" + id.uuidString)
do { _ = try NativePredicateReference.expression(opaque, sourceIDs: sourceIDs, resolver: resolve); assertionFailure("Opaque source expression must reject") } catch {}
let aggregate = try NativePredicateReference.constant(["refs": [original, unrelated]], sourceIDs: sourceIDs, resolver: resolve)
assert(aggregate.changed)
let refs = (aggregate.value as! [String: Any])["refs"] as! [Any]
assert(refs[0] as AnyObject === replacement && refs[1] as AnyObject === unrelated)
let secondGuard = NSPredicate(format: "secondGuard == 0")
let thirdGuard = NSPredicate(format: "thirdGuard == 0")
let night = NSCompoundPredicate(orPredicateWithSubpredicates: [time, NSPredicate(format: "sunrise > now()")])
let nested = NSCompoundPredicate(andPredicateWithSubpredicates: [
    NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSCompoundPredicate(andPredicateWithSubpredicates: [night, customPresence, sourceClause]), secondGuard
    ]), thirdGuard
])
let flattened = try NativePredicateReference.flattenConjunctions(nested)
assert(flattened.changed)
let flat = flattened.predicate as! NSCompoundPredicate
assert(flat.compoundPredicateType == .and && flat.subpredicates.count == 5)
for (index, leaf) in [night, customPresence, sourceClause, secondGuard, thirdGuard].enumerated() {
    assert(flat.subpredicates[index] as AnyObject === leaf)
}
let secondPass = try NativePredicateReference.flattenConjunctions(flat)
let pairPass = try NativePredicateReference.flattenConjunctions(sourceClause)
let orPass = try NativePredicateReference.flattenConjunctions(guarded)
assert(!secondPass.changed && !pairPass.changed && !orPass.changed)
let bools = ["night", "presence", "shabbosOff", "yomTovOff", "lateNightOff"].map { NSPredicate(format: "%K == YES", $0) }
let logic = NSCompoundPredicate(andPredicateWithSubpredicates: [
    NSCompoundPredicate(andPredicateWithSubpredicates: [NSCompoundPredicate(andPredicateWithSubpredicates: Array(bools.prefix(3))), bools[3]]), bools[4]
])
let normalizedLogic = try NativePredicateReference.flattenConjunctions(logic).predicate
for mask in 0..<32 {
    var input: [String: Bool] = [:]
    for (i, key) in ["night", "presence", "shabbosOff", "yomTovOff", "lateNightOff"].enumerated() { input[key] = mask & (1 << i) != 0 }
    assert(logic.evaluate(with: input) == normalizedLogic.evaluate(with: input))
}
let a = UUID(), b = UUID(), c = UUID()
let add = try AgentMembership.desired([a,b], replacement: nil, additions: [c], removals: nil)
assert(add == Set([a,b,c]))
let noop = try AgentMembership.desired([a,b], replacement: nil, additions: [a], removals: nil)
assert(noop == Set([a,b]))
let cleared = try AgentMembership.desired([a,b], replacement: [], additions: nil, removals: nil)
assert(cleared.isEmpty)
do { _ = try AgentMembership.desired([a], replacement: nil, additions: [b], removals: [b]); assertionFailure("Overlap must reject") } catch {}
do { _ = try AgentMembership.desired([a], replacement: nil, additions: nil, removals: [b]); assertionFailure("Unknown removal must reject") } catch {}
do { _ = try AgentMembership.desired([a], replacement: [b], additions: [], removals: nil); assertionFailure("Mixed replace/add must reject") } catch {}
do { _ = try AgentMembership.desired([a], replacement: nil, additions: [b,b], removals: nil); assertionFailure("Duplicates must reject") } catch {}
assert(AgentScalar.normalized(.number(0), format: "bool") == .bool(false))
assert(AgentScalar.normalized(.number(1), format: "bool") == .bool(true))
assert(AgentScalar.normalized(.number(2), format: "bool") == .number(2))
assert(AgentScalar.normalized(.number(1), format: "uint8") == .number(1))
assert(AgentScalar.normalized(.bool(true), format: "uint8") == .bool(true))
let transaction = UUID(), session = UUID(), home = UUID(), group = UUID(), service = UUID()
let raw = "{\"id\":\"\(transaction)\",\"sessionID\":\"\(session)\",\"homeID\":\"\(home)\",\"operation\":\"update_group\",\"objectID\":\"\(group)\",\"addServiceIDs\":[\"\(service)\"]}"
let request = try JSONDecoder().decode(AgentRequest.self, from: Data(raw.utf8))
let canonical = try request.canonicalData()
for _ in 0..<100 { let encoded = try request.canonicalData(); assert(encoded == canonical) }
print("Native migration preservation passed")
'''
        with tempfile.TemporaryDirectory() as temp:
            path=pathlib.Path(temp);(path/'AgentValue.swift').write_text('import Foundation\nenum AgentValue:'+enum)
            (path/'main.swift').write_text(fixture)
            result=subprocess.run(['xcrun','swiftc',str(path/'AgentValue.swift'),str(source/'AgentScalar.swift'),str(source/'AgentMembership.swift'),str(source/'NativePredicateReference.swift'),str(path/'main.swift'),'-o',str(path/'check')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(path/'check')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('preservation passed',result.stdout)
