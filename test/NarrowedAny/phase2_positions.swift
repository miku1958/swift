// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Phase 1 + 2a comprehensive position test — verify `A | B` parses in
// every type position we care about, then assert the runtime behaviour
// matches Phase 1's desugar-to-Any contract (Phase 2a doesn't change
// runtime semantics).

import Foundation

// MARK: 1. Basic variables
let v1: Int | String = 42
let v2: Int | String = "hello"
let v3: Int | String | Double = 3.14
let v4: (Int | String) | Bool = true
assert(type(of: v1) == Int.self)
assert(v2 as? String == "hello")
assert(v3 as? Double == 3.14)
assert(v4 as? Bool == true)

// MARK: 2. Function parameters / return values
func describe(_ x: Int | String) -> String {
    if let i = x as? Int    { return "Int(\(i))" }
    if let s = x as? String { return "Str(\(s))" }
    return "?"
}
func makeInt() -> Int | String { 7 }
func makeStr() -> Int | String { "hi" }
assert(describe(7) == "Int(7)")
assert(describe("hi") == "Str(hi)")
assert(describe(makeInt()) == "Int(7)")
assert(describe(makeStr()) == "Str(hi)")

// MARK: 3. Containers (Array, Dictionary)
let xs: [Int | String] = [1, "two", 3, "four"]
assert(xs.count == 4)
assert(describe(xs[0]) == "Int(1)")
assert(describe(xs[1]) == "Str(two)")
assert(describe(xs[2]) == "Int(3)")
assert(describe(xs[3]) == "Str(four)")

let dict: [String: Int | Bool] = ["a": 1, "b": true, "c": 2]
assert(dict["a"] as? Int == 1)
assert(dict["b"] as? Bool == true)
assert(dict["c"] as? Int == 2)

// MARK: 4. typealias + nesting
typealias Token = Int | String | Data
let t: Token = 42
assert(t as? Int == 42)

typealias Outer = (Int | String) | Bool
let o: Outer = "outer"
assert(o as? String == "outer")

// MARK: 5. Function-type literals shaped as `((A | B)) -> R`
let fn: ((Int | String)) -> String = { describe($0) }
assert(fn(99) == "Int(99)")
assert(fn("zz") == "Str(zz)")

// MARK: 6. Optional interaction — Int? IS the leaf type
let none: Int? = nil
let opt1: Int? | String = "with-some"
let opt2: Int? | String = none
let opt3: Int? | String = 42
assert(opt1 as? String == "with-some")
assert((opt2 as? Int?) == .some(Int?.none))
assert((opt3 as? Int?) == .some(.some(42)))

// MARK: 7. switch with all leaf cases (default still required because
// Phase 1+2a desugars to `Any`)
let s: Int | String | Double = 3.14
var matched: String? = nil
switch s {
case let i as Int:    matched = "Int(\(i))"
case let s as String: matched = "Str(\(s))"
case let d as Double: matched = "Double(\(d))"
default:              matched = "other"
}
assert(matched == "Double(3.14)")

// MARK: 8. Flat vs explicitly-nested shapes coexist
let flat: Int | String | Bool      = true
let nested: (Int | String) | Bool  = true
let nestedR: Int | (String | Bool) = "right"
assert(flat as? Bool == true)
assert(nested as? Bool == true)
assert(nestedR as? String == "right")

// MARK: 9. Mixed with `&` (intersection) — parser must accept both.
// (`.description` calls go through Any in Phase 1+2a; we only assert the
// parse + injection succeed here.)
let mixed: Int | (CustomStringConvertible & CustomDebugStringConvertible) = "mixed"
assert(mixed as? String == "mixed")
