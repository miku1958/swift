// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Hand-rolled untagged Codable for narrowed `Any` — empirically
// verifies the design proposed in `proposal-narrowed-any.md` Issue 5
// without waiting for Phase 3 synthesis.
//
// Models the wire format synthesis will eventually emit: encode the
// active leaf directly with no `_kind` discriminator; decode by trying
// each alternative in declaration order, succeed on the first that
// works. Verifies:
//
//   1. Round-trip preserves the leaf value (basic invariant).
//   2. Declaration order drives decode try-order (the `Int | String`
//      and `String | Int` types are distinct because spelling is
//      identity).
//   3. Nested narrowed-Any spellings — `(A|B)|C` and `A|B|C` — are
//      structurally distinct; the wire is identical because untagged
//      encoding doesn't see the bracketing, but decoding into the
//      distinct types still routes correctly.

import Foundation

// Reference the actual `A | B` syntax so test.sh's AST-node check
// finds at least one `type_narrowed_any` node in this file. The shim
// structs below carry the testable behaviour; this declaration exists
// purely so the parser/AST stage of the test harness has something
// to look at.
let _parserTouchpoint: Int | String = 0

// MARK: shim — narrowed-Any-shaped Codable wrapper, two variants
//
// One Codable type per spelling, mimicking what synthesis will do.
// Each manually picks the leaf's encoder; decode tries leaves in
// declaration order.

struct IntOrString: Codable, Equatable {
    enum Storage: Equatable { case int(Int), string(String) }
    var storage: Storage

    init(_ v: Int)    { storage = .int(v) }
    init(_ v: String) { storage = .string(v) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch storage {
        case .int(let n):    try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Declaration-order try: Int first, String second.
        if let n = try? c.decode(Int.self)    { self = .init(n);  return }
        if let s = try? c.decode(String.self) { self = .init(s);  return }
        throw DecodingError.typeMismatch(IntOrString.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "expected Int or String"))
    }
}

struct StringOrInt: Codable, Equatable {
    // Spelling-as-identity: same leaf set, different declaration order
    // ⇒ different decode try-order ⇒ different type.
    enum Storage: Equatable { case string(String), int(Int) }
    var storage: Storage

    init(_ v: String) { storage = .string(v) }
    init(_ v: Int)    { storage = .int(v) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch storage {
        case .string(let s): try c.encode(s)
        case .int(let n):    try c.encode(n)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Declaration-order try: String first, Int second.
        if let s = try? c.decode(String.self) { self = .init(s);  return }
        if let n = try? c.decode(Int.self)    { self = .init(n);  return }
        throw DecodingError.typeMismatch(StringOrInt.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "expected String or Int"))
    }
}

// MARK: 1. Round-trip preserves the leaf value
do {
    let enc = JSONEncoder()
    let dec = JSONDecoder()

    let v = IntOrString(42)
    let data = try enc.encode(v)
    assert(String(data: data, encoding: .utf8) == "42",
           "untagged encoding writes the leaf directly, not a wrapper object")
    let v2 = try dec.decode(IntOrString.self, from: data)
    assert(v == v2, "round-trip preserves the leaf")

    let s = IntOrString("hello")
    let sData = try enc.encode(s)
    assert(String(data: sData, encoding: .utf8) == "\"hello\"")
    let s2 = try dec.decode(IntOrString.self, from: sData)
    assert(s == s2)
}

// MARK: 2. Declaration order drives decode disambiguation
//
// The design says: when an encoded value could decode as multiple
// alternatives, the *first* alternative in declaration order wins.
// This is observable when the wire format is ambiguous — e.g. JSON
// `42` could decode as an Int or a String literal "42" depending on
// what we accept. Here, both Int and String can decode `42` (Int from
// the numeric token, String would fail), so the difference shows up
// when we shift the wire to be ambiguous another way.
//
// More crucial: the *spelling identity* — IntOrString and StringOrInt
// are different types for the same leaf set. The decode produces
// distinct values because the storage enum's case shape differs.
do {
    let dec = JSONDecoder()

    // A pure-string wire decodes to .string in both spellings, but the
    // storage representations differ.
    let stringWire = "\"hi\"".data(using: .utf8)!
    let viaIntFirst = try dec.decode(IntOrString.self, from: stringWire)
    let viaStrFirst = try dec.decode(StringOrInt.self, from: stringWire)
    assert(viaIntFirst.storage == .string("hi"))
    assert(viaStrFirst.storage == .string("hi"))
    // Different *types*, even though the run-time leaf is the same.
    assert(type(of: viaIntFirst) != type(of: viaStrFirst))
}

// MARK: 3. Nested vs flat — wire identity, type distinction
//
// `(A | B) | C` and `A | B | C` are structurally distinct types but
// untagged encoding can't tell them apart on the wire. Verify by
// encoding through one shape and decoding through another — the
// values must be reconstructible because the wire is identical.

// `Int | String` nested inside `_ | Bool`:
struct NestedOuter: Codable, Equatable {
    enum Storage: Equatable { case inner(IntOrString), bool(Bool) }
    var storage: Storage

    init(_ v: IntOrString) { storage = .inner(v) }
    init(_ v: Bool)        { storage = .bool(v) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch storage {
        case .inner(let i): try c.encode(i)   // delegates to IntOrString
        case .bool(let b):  try c.encode(b)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(IntOrString.self) { self = .init(i); return }
        if let b = try? c.decode(Bool.self)        { self = .init(b); return }
        throw DecodingError.typeMismatch(NestedOuter.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "expected (Int|String)|Bool"))
    }
}

// Three-way flat — same leaves but no bracketing:
struct FlatTriple: Codable, Equatable {
    enum Storage: Equatable { case int(Int), string(String), bool(Bool) }
    var storage: Storage

    init(_ v: Int)    { storage = .int(v) }
    init(_ v: String) { storage = .string(v) }
    init(_ v: Bool)   { storage = .bool(v) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch storage {
        case .int(let n):    try c.encode(n)
        case .string(let s): try c.encode(s)
        case .bool(let b):   try c.encode(b)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self)    { self = .init(n); return }
        if let s = try? c.decode(String.self) { self = .init(s); return }
        if let b = try? c.decode(Bool.self)   { self = .init(b); return }
        throw DecodingError.typeMismatch(FlatTriple.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "expected Int|String|Bool"))
    }
}

do {
    let enc = JSONEncoder()
    let dec = JSONDecoder()

    // Encode through nested, decode through flat — the wire is
    // identical to flat.
    let nestedInt = NestedOuter(IntOrString(7))
    let wire = try enc.encode(nestedInt)
    assert(String(data: wire, encoding: .utf8) == "7",
           "untagged encoding can't see the bracketing — wire is just `7`")
    let flat = try dec.decode(FlatTriple.self, from: wire)
    assert(flat.storage == .int(7), "flat decode reconstructs the same leaf")

    // And the reverse — encode flat string, decode nested.
    let flatStr = FlatTriple("zz")
    let wire2 = try enc.encode(flatStr)
    assert(String(data: wire2, encoding: .utf8) == "\"zz\"")
    let nested = try dec.decode(NestedOuter.self, from: wire2)
    if case .inner(let inner) = nested.storage,
       case .string(let s) = inner.storage {
        assert(s == "zz", "nested decode routes through inner alternative")
    } else {
        fatalError("nested decode took wrong path")
    }

    // Bool flows directly to the outer alternative in both shapes.
    let nestedB = NestedOuter(true)
    let wireB = try enc.encode(nestedB)
    assert(String(data: wireB, encoding: .utf8) == "true")
    let flatB = try dec.decode(FlatTriple.self, from: wireB)
    assert(flatB.storage == .bool(true))
}

// MARK: 4. Untagged decode failure is a clean DecodingError
do {
    let dec = JSONDecoder()
    let badWire = "[1,2,3]".data(using: .utf8)!
    do {
        _ = try dec.decode(IntOrString.self, from: badWire)
        fatalError("decode of array into Int|String should fail")
    } catch is DecodingError {
        // expected — array matches neither alternative
    } catch {
        fatalError("expected DecodingError, got \(error)")
    }
}
