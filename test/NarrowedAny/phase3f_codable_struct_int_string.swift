// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Row #36 baseline test: synthesised Codable on a struct with a
// narrowed-`Any` stored property (`struct A: Codable { let b: Int | String }`)
// directly against raw JSON wire forms.
//
// The existing phase3f_codable_*.swift tests cover Wrap<Status | Int>
// (enum leaf), Array<V | Bool> nesting and similar shapes; this one
// nails down the plain `Int | String` baseline for both spelling orders
// and the four wire shapes the design has to handle:
//
//   • `{"b": 7}`        — number wire
//   • `{"b": "7"}`      — string wire that *looks* like an Int
//   • `{"b": "hello"}`  — string wire that doesn't look like an Int
//   • `{"b": true}`     — wire that matches neither leaf (DecodingError)
//
// The `{"b": "7"}` case is the one that nails down the design's
// "try-each-leaf in declaration order, no implicit coerce" rule:
// `Int.init(from:)` is tried first, fails because the JSON token is a
// string; the decoder falls through to `String.init(from:)`, which
// succeeds and stores `"7"` (a String), *not* `7` (an Int).
//
// Cross-spelling (`String | Int`) flips the try-order so the same
// `{"b": "7"}` resolves String-first; `{"b": 7}` falls through String
// and lands as Int. Spelling-as-identity at the type level, but
// declaration-order at the wire-decode level.

import Foundation

struct IS: Codable {
    let b: Int | String
}

struct SI: Codable {
    let b: String | Int
}

// MARK: 1. Round-trip for each leaf, both spellings.
do {
    let enc = JSONEncoder()
    let dec = JSONDecoder()

    // IS (Int | String) — Int leaf.
    let isInt = IS(b: 7)
    let isIntWire = try enc.encode(isInt)
    assert(String(data: isIntWire, encoding: .utf8) == #"{"b":7}"#,
           "IS Int leaf encodes as raw number")
    let isIntBack = try dec.decode(IS.self, from: isIntWire)
    assert(isIntBack.b as? Int == 7, "IS round-trip preserves Int leaf")
    assert(!(isIntBack.b is String), "Int leaf must not also satisfy `is String`")

    // IS (Int | String) — String leaf.
    let isStr = IS(b: "hello")
    let isStrWire = try enc.encode(isStr)
    assert(String(data: isStrWire, encoding: .utf8) == #"{"b":"hello"}"#,
           "IS String leaf encodes as raw string")
    let isStrBack = try dec.decode(IS.self, from: isStrWire)
    assert(isStrBack.b as? String == "hello", "IS round-trip preserves String leaf")
    assert(!(isStrBack.b is Int), "String leaf must not also satisfy `is Int`")

    // SI (String | Int) — same values, mirrored declaration order.
    let siInt = SI(b: 7)
    let siIntWire = try enc.encode(siInt)
    assert(String(data: siIntWire, encoding: .utf8) == #"{"b":7}"#,
           "SI Int leaf encodes as raw number — wire is order-agnostic")
    let siIntBack = try dec.decode(SI.self, from: siIntWire)
    assert(siIntBack.b as? Int == 7, "SI round-trip preserves Int leaf")

    let siStr = SI(b: "hello")
    let siStrWire = try enc.encode(siStr)
    assert(String(data: siStrWire, encoding: .utf8) == #"{"b":"hello"}"#)
    let siStrBack = try dec.decode(SI.self, from: siStrWire)
    assert(siStrBack.b as? String == "hello")
}

// MARK: 2. The decisive case — `{"b": "7"}` resolves to the
// declaration-order-first leaf that accepts the wire token, NOT to
// whatever leaf "could" hold the value after coercion.
do {
    let dec = JSONDecoder()
    let wire = #"{"b":"7"}"#.data(using: .utf8)!

    // Int | String: Int.init(from:) sees a string token, throws
    // typeMismatch; decoder falls through to String, which decodes "7".
    // Result: b is String "7", NOT Int 7.
    let isBack = try dec.decode(IS.self, from: wire)
    assert(isBack.b as? String == "7",
           "IS `\"7\"`: Int decode fails, fallthrough lands String")
    assert(!(isBack.b is Int),
           "IS `\"7\"` must NOT silently coerce to Int — that would defeat spelling-as-identity")

    // String | Int: String.init(from:) hits first, decodes "7" directly.
    let siBack = try dec.decode(SI.self, from: wire)
    assert(siBack.b as? String == "7",
           "SI `\"7\"`: String wins first, b is String")
}

// MARK: 3. Number wire under flipped spelling — the symmetric
// declaration-order test.
do {
    let dec = JSONDecoder()
    let wire = #"{"b":7}"#.data(using: .utf8)!

    // Int | String: Int wins immediately.
    let isBack = try dec.decode(IS.self, from: wire)
    assert(isBack.b as? Int == 7, "IS `7`: Int wins first")

    // String | Int: String.init(from:) sees a number token, throws;
    // fallthrough to Int, which decodes 7.
    let siBack = try dec.decode(SI.self, from: wire)
    assert(siBack.b as? Int == 7,
           "SI `7`: String decode fails, fallthrough lands Int")
    assert(!(siBack.b is String),
           "SI `7` must NOT silently coerce to String")
}

// MARK: 4. Plain string wire (no Int-shaped digits) — falls through
// the same way regardless of spelling.
do {
    let dec = JSONDecoder()
    let wire = #"{"b":"hello"}"#.data(using: .utf8)!

    let isBack = try dec.decode(IS.self, from: wire)
    assert(isBack.b as? String == "hello",
           "IS `\"hello\"`: Int fails, fallthrough lands String")

    let siBack = try dec.decode(SI.self, from: wire)
    assert(siBack.b as? String == "hello",
           "SI `\"hello\"`: String wins first")
}

// MARK: 5b. Reflection of a top-level struct field of narrowed-Any
// type displays the actual value, not `()`.
//
// Pre-row-#35 fix, `print(IS(b: 7))` showed `IS(b: ())` and the
// runtime emitted "the Swift runtime was unable to demangle the
// type of field 'b' ... 'Si_SSXN'". Slice 32 routed lazy-demangle
// type-refs through getTypeRefByFunction *only when* the deployment
// target's runtimeCompatVersion was older than the version pinned
// by getRuntimeVersionThatSupportsDemanglingType (Swift_6_2). On a
// current macOS SDK that comparison is false and the static mangled
// name leaks out — the system runtime then chokes on `XN`.
//
// The row-#35 part-(c) fix moves the narrowed-Any short-circuit
// into mangledNameIsUnknownToDeployTarget directly: any type tree
// that contains a NarrowedAnyType always gets the per-module
// accessor function, regardless of deployment target. Mirror,
// String(describing:) and print all then read the actual leaf.
do {
    let v = IS(b: 7)
    let s = String(describing: v)
    assert(s == "IS(b: 7)",
           "String(describing:) of narrowed-Any field shows the leaf value, got: \(s)")

    let v2 = IS(b: "hello")
    let s2 = String(describing: v2)
    assert(s2 == #"IS(b: "hello")"#,
           "String(describing:) shows the String leaf, got: \(s2)")

    let m = Mirror(reflecting: v)
    var sawB = false
    for child in m.children {
        if child.label == "b" {
            assert((child.value as? Int) == 7,
                   "Mirror reads top-level struct field as Int 7, not ()")
            sawB = true
        }
    }
    assert(sawB, "Mirror exposes the `b` child label")
}

// MARK: 6. Wire shape matches no leaf — both spellings raise
// DecodingError, not a silent default.
do {
    let dec = JSONDecoder()
    let wire = #"{"b":true}"#.data(using: .utf8)!

    do {
        _ = try dec.decode(IS.self, from: wire)
        fatalError("IS decoding `true` should fail — Bool is not in {Int, String}")
    } catch is DecodingError {
        // expected
    } catch {
        fatalError("IS expected DecodingError on `true`, got \(error)")
    }

    do {
        _ = try dec.decode(SI.self, from: wire)
        fatalError("SI decoding `true` should fail — Bool is not in {String, Int}")
    } catch is DecodingError {
        // expected
    } catch {
        fatalError("SI expected DecodingError on `true`, got \(error)")
    }
}
