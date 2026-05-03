// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Edge-case parser / AST tests for narrowed `Any`. These exercise
// shapes called out in todo.md §4 (`main.swift` test bed follow-up) that are
// observable today even though Sema still desugars to `Any`.

import Foundation

// MARK: 1. Multi-union tuple parameter list
// todo.md §3.2 / §4 — `((A|B), (C|D)) -> E`. Each tuple element is its
// own narrowed `Any`; both must parse and inject.
let twoUnions: ((Int | String), (Bool | Double)) -> String = { lhs, rhs in
    let l: String
    if let i = lhs as? Int    { l = "Int(\(i))"    }
    else if let s = lhs as? String { l = "Str(\(s))" }
    else { l = "?" }
    let r: String
    if let b = rhs as? Bool   { r = "Bool(\(b))"   }
    else if let d = rhs as? Double { r = "Dbl(\(d))" }
    else { r = "?" }
    return "\(l)/\(r)"
}
assert(twoUnions(7, true) == "Int(7)/Bool(true)")
assert(twoUnions("hi", 3.14) == "Str(hi)/Dbl(3.14)")

// MARK: 2. Spelling identity — `A | B` and `B | A` are different types
// todo.md §4 — `Array<A | B>` vs `Array<B | A>` invariance.
// Each container has its own spelling. Today they all desugar to
// `Array<Any>` so values flow freely; the spelling check is a
// future-state assertion that today's PoC won't enforce.
let ab: [Int | String] = [1, "two"]
let ba: [String | Int] = ["two", 1]
assert(ab.count == 2)
assert(ba.count == 2)
assert(ab[0] as? Int == 1)
assert(ba[0] as? String == "two")

// MARK: 3. Protocol composition inside a leaf — `Int | (P & Q)`
// todo.md §3.4 / §4 — `(P & Q) | (P & R)` mustn't normalise to
// `P & (Q | R)`. Today we just verify both shapes parse and round-trip
// without confusing the parser for `&` precedence.
let composed: Int | (CustomStringConvertible & CustomDebugStringConvertible) = "composed"
assert(composed as? String == "composed")

let bothComposed:
    (CustomStringConvertible & CustomDebugStringConvertible)
    | (Sequence & IteratorProtocol) = "v"
assert(bothComposed as? String == "v")

// MARK: 4. Generic argument carrying a union — `Optional<A | B>` and
// `Result<A | B, Error>`-shaped uses (covered by parser only; no
// generic specialisation today).
let optUnion: Optional<Int | String> = .some(42)
assert(optUnion as? Int == 42)

// MARK: 5. Closure return type with union — pure parser exercise.
let firstNonEmpty: ([String]) -> String | Bool = { xs in
    guard let first = xs.first else { return false }
    return first
}
assert(firstNonEmpty([]) as? Bool == false)
assert(firstNonEmpty(["x"]) as? String == "x")

// MARK: 6. Three-way nesting — `((A | B) | C) | D`. Type identity is
// the spelling so this is structurally distinct from `A | B | C | D`,
// but values flow because of leaf injection through Any in the PoC.
let deeplyNested: ((Int | String) | Bool) | Double = 3.14
assert(deeplyNested as? Double == 3.14)

// MARK: 7. Source compatibility — `|` in expression context is still
// the existing bitwise-or operator. todo §4 / Issue 1: a parser that
// recognises `|` as a type operator must not regress this.
do {
    let lhs: UInt8 = 0b1010
    let rhs: UInt8 = 0b0101
    let combined = lhs | rhs
    assert(combined == 0b1111, "expression-position `|` must stay bitwise-or")
}

// And the cross-context combination: a bitwise-or expression assigned
// to a narrowed-`Any`-typed binding works because the result is still
// an Int that can flow through leaf injection.
let bitwise: Int | String = (0xF0 | 0x0F)
assert(bitwise as? Int == 0xFF)

// MARK: 8. Generic extension argument matching — same-spelling works,
// cross-spelling and leaf-injection are diagnosed (not crashed). This
// is the regression for a Sema ICE in `matchDeepEqualityTypes` that
// used to fire `castTo<BoundGenericType>` on a NarrowedAnyType when
// `[Int | String]` met `[String | Int]` at extension-method lookup
// (the function had no NarrowedAnyType branch and fell through to the
// bound-generic `castTo` at the bottom). Spelling-as-identity still
// applies at type-identity boundaries: extension dispatch is
// per-spelling, not per-leaf-set.
extension Array where Element == String | Int {
    func extSummary() -> Int { return self.count }
}
do {
    let ys: [String | Int] = ["a", 7, "b"]
    assert(ys.extSummary() == 3)        // same spelling → matches the extension

    // Cross-spelling reshape via explicit `as` works end-to-end.
    // `Array<Int|String>` and `Array<String|Int>` share bit-identical
    // memory layout (each element is narrowed-Any reusing Any
    // singleton metadata), so the cast is a SIL-level type relabel
    // — no element walk, no buffer reallocation.
    let zs: [Int | String] = [1, "a"]
    assert((zs as [String | Int]).extSummary() == 2)        // inline reshape
    let reshaped = zs as [String | Int]
    assert(reshaped.extSummary() == 2)                      // named-binding reshape

    // The following lines each diagnose cleanly today (cross-spelling
    // requires `as`, leaf-injection at the extension boundary is not
    // implemented in v1) — the prototype no longer ICEs in either:
    //   _ = zs.extSummary()             // error: cross-spelling, requires `as`
    //   let xs: [String]       = ["a"]
    //   _ = xs.extSummary()             // error: leaf-injection at ext not impl
}

// MARK: 9. Slice-18 leaf-membership false-positive regressions.
// audit pass #2 surfaced three pre-existing slice-18 bugs when the
// disjoint-cast warning flipped to a hard error. Each got fixed in
// the same commit (swift fork 0279a8953d7); the runnable shapes
// below lock the fixes in so they don't regress.
do {
    // (a) `Int?` is a real leaf of `Int? | String` and the
    // partial-overlap `as?` should compile cleanly. Slice 18
    // originally peeled an Optional off `toType` and then compared
    // canonical-type pointers, so `as? Int?` ended up looking up
    // `Int` against a leaf set that only contained `Optional<Int>`
    // — false-positive disjoint. Fix: don't peel `toType`; switch
    // to `Type::isEqual` membership.
    let opt1: Int? | String = 42
    assert((opt1 as? Int?) == .some(.some(42)))
    let opt2: Int? | String = "hi"
    assert((opt2 as? Int?) == nil)

    // (b) Protocol-composition leaf: `Int | (P & Q)` against a
    // concrete target that conforms to `P & Q` is feasible at
    // runtime. Slice 18 treated existential leaves as opaque and
    // false-positived `as? String` as disjoint. Fix: decompose via
    // ExistentialLayout, check conformance per member protocol.
    let mixed: Int | (CustomStringConvertible & CustomDebugStringConvertible) = "mixed"
    assert((mixed as? String) == "mixed")
    let mixedI: Int | (CustomStringConvertible & CustomDebugStringConvertible) = 7
    assert((mixedI as? String) == nil)
    assert((mixedI as? Int) == 7)

    // (c) Pattern-form mirror — `case let _ as Int?` on a switch
    // over `Int? | String` was the same false positive in
    // TypeCheckPattern's IsPattern path. Same canonical-equality
    // + protocol-composition fixes apply.
    let v: Int? | String = nil as Int?
    switch v {
    case let i as Int?:
        assert(i == nil, "Int? leaf matched, value is Optional<Int>.none")
    case let s as String:
        assert(false, "String arm should not fire, got \(s)")
    }
}
