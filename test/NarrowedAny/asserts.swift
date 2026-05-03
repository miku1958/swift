// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// One-click smoke test for `A | B` parser + Phase 2a Type node.
// Each property of the design is verified with `assert(...)`. If anything
// regresses, the program traps; otherwise it exits 0 silently.
//
// Run via ../narrowed-any/test.sh, or directly with the freshly built swift:
//   ../build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64/bin/swift \
//       -Xfrontend -disable-experimental-parser-round-trip test-asserts.swift

// MARK: 1. Basic 2-arity — leaf injection + as? extraction
do {
    let v1: Int | String = 42
    assert(v1 as? Int == 42)
    assert(v1 as? String == nil)
    // assert((v1 as? Bool) == nil)
    // ⛔ Bool is disjoint from Int|String's leaf set — per decision
    // row #18 this is a hard compile error in any of as / as? / as!.
    // The runtime would return nil; Sema rejects the form upfront.

    let v2: Int | String = "hello"
    assert(v2 as? Int == nil)
    assert(v2 as? String == "hello")
}

// MARK: 2. Flat 3-arity (Int | String | Double)
do {
    let i: Int | String | Double = 7
    assert(i as? Int == 7)
    assert(i as? String == nil)
    assert(i as? Double == nil)

    let s: Int | String | Double = "hi"
    assert(s as? Int == nil)
    assert(s as? String == "hi")
    assert(s as? Double == nil)

    let d: Int | String | Double = 3.14
    assert(d as? Int == nil)
    assert(d as? String == nil)
    assert(d as? Double == 3.14)
}

// MARK: 3. Nested (Int | String) | Bool — outer 2-arity wrapping inner 2-arity
do {
    let y1: (Int | String) | Bool = true
    assert(y1 as? Bool == true)
    assert(y1 as? Int == nil)

    let y2: (Int | String) | Bool = 7
    assert(y2 as? Int == 7)
    assert(y2 as? Bool == nil)

    let y3: (Int | String) | Bool = "deep"
    assert(y3 as? String == "deep")
}

// MARK: 4. Right-nested Int | (String | Bool) — distinct shape, same leaf set
do {
    let z1: Int | (String | Bool) = 99
    assert(z1 as? Int == 99)

    let z2: Int | (String | Bool) = "right"
    assert(z2 as? String == "right")

    let z3: Int | (String | Bool) = false
    assert(z3 as? Bool == false)
}

// MARK: 5. switch with leaf case patterns (default required because Phase 1+2a
// desugars to `Any`; real exhaustiveness over leaves is Phase 3)
func describe2(_ x: Int | String) -> String {
    switch x {
    case let i as Int:    return "Int(\(i))"
    case let s as String: return "Str(\(s))"
    default:              return "?"
    }
}
assert(describe2(42) == "Int(42)")
assert(describe2("hi") == "Str(hi)")

func describe3(_ x: Int | String | Double) -> String {
    switch x {
    case let i as Int:    return "Int(\(i))"
    case let s as String: return "Str(\(s))"
    case let d as Double: return "Double(\(d))"
    default:              return "?"
    }
}
assert(describe3(7) == "Int(7)")
assert(describe3("zz") == "Str(zz)")
assert(describe3(2.5) == "Double(2.5)")

// MARK: 6. Function params and returns
func make() -> Int | String {
    return 42
}
let m = make()
assert(m as? Int == 42)

// MARK: 7. Container types (Array, Dictionary)
let xs: [Int | String] = [1, "two", 3, "four"]
assert(xs.count == 4)
assert(xs[0] as? Int == 1)
assert(xs[1] as? String == "two")
assert(xs[2] as? Int == 3)
assert(xs[3] as? String == "four")

let dict: [String: Int | Bool] = ["a": 1, "b": true]
assert(dict["a"] as? Int == 1)
assert(dict["b"] as? Bool == true)

// MARK: 8. typealias preserves the alternation
typealias Token = Int | String | Bool
let t1: Token = 9
let t2: Token = "ok"
let t3: Token = false
assert(t1 as? Int == 9)
assert(t2 as? String == "ok")
assert(t3 as? Bool == false)

// MARK: 9. Optional alternative — Int? IS the leaf type
do {
    let none: Int? = nil
    let opt1: Int? | String = 42                 // Int? .some(42)
    let opt2: Int? | String = none               // Int? .none
    let opt3: Int? | String = "string-arm"
    assert((opt1 as? Int?) == .some(.some(42)))
    assert((opt2 as? Int?) == .some(Int?.none))
    assert(opt3 as? String == "string-arm")
}

// MARK: 10. Mixed with `&` (intersection) — parser must accept both
do {
    let mixed: Int | (CustomStringConvertible & CustomDebugStringConvertible) = "mixed"
    assert(mixed as? String == "mixed")
}

// MARK: 11. As function-type return
let factory: () -> Int | String = { 7 }
let r1 = factory()
assert(r1 as? Int == 7)

// MARK: 12. Function-type parameter shaped as `(A | B) -> R`
let consume: ((Int | String)) -> String = { x in
    if let i = x as? Int    { return "I:\(i)" }
    if let s = x as? String { return "S:\(s)" }
    return "?"
}
assert(consume(99) == "I:99")
assert(consume("zz") == "S:zz")
