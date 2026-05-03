// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Phase 3.F slice 6 runtime tests: per-leaf Equatable dispatch on
// narrowed-Any types. Exercises same-leaf equality, cross-leaf
// inequality, multi-arity, and Optional<NarrowedAny> equality
// (which composes through Optional's generic Equatable witness).

// MARK: 1. Two-leaf same-leaf equality
do {
    let a: Int | String = 5
    let b: Int | String = 5
    assert(a == b, "Int 5 == Int 5 should be true")

    let s1: Int | String = "hello"
    let s2: Int | String = "hello"
    assert(s1 == s2, "String equality should hold")
}

// MARK: 2. Two-leaf same-leaf inequality
do {
    let a: Int | String = 5
    let b: Int | String = 7
    assert(!(a == b), "Int 5 != Int 7 should be false")

    let s1: Int | String = "hello"
    let s2: Int | String = "world"
    assert(!(s1 == s2), "different strings should not be equal")
}

// MARK: 3. Two-leaf cross-leaf inequality
do {
    let i: Int | String = 5
    let s: Int | String = "5"
    assert(!(i == s), "Int and String are never equal even with same description")
}

// MARK: 4. Three-leaf
do {
    let a: Int | String | Double = 3.14
    let b: Int | String | Double = 3.14
    assert(a == b, "3-leaf same Double should be true")

    let c: Int | String | Double = "hi"
    assert(!(a == c), "3-leaf different leaf types should be false")

    let d: Int | String | Double = 7
    let e: Int | String | Double = 7
    assert(d == e, "3-leaf same Int should be true")
}

// MARK: 5. Optional<NarrowedAny> equality (composes through Optional)
do {
    let a: (Int | String)? = 5
    let b: (Int | String)? = 5
    assert(a == b, "Optional<Int|String> wrapping equal Ints should be equal")

    let n1: (Int | String)? = nil
    let n2: (Int | String)? = nil
    assert(n1 == n2, "nil == nil")

    let v: (Int | String)? = 5
    assert(!(v == nil), "Some != nil")

    let c: (Int | String)? = "hi"
    assert(!(a == c), "different leaves through Optional should be false")
}

// MARK: 6. Equatable in generic position
do {
    func areEqual<T: Equatable>(_ x: T, _ y: T) -> Bool { x == y }
    let a: Int | String = 42
    let b: Int | String = 42
    assert(areEqual(a, b), "Equatable witness should resolve in generic position")

    let c: Int | String = "x"
    assert(!areEqual(a, c), "different leaves in generic position")
}

// MARK: 7. Array<NarrowedAny> Equatable-using stdlib APIs
do {
    let arr: [Int | String] = [1, "two", 3, "four", 5]

    let needle1: Int | String = "two"
    assert(arr.contains(where: { $0 == needle1 }), "contains(where: ==) string")
    assert(arr.firstIndex(of: needle1) == 1, "firstIndex of String")

    let needle2: Int | String = 3
    assert(arr.contains(needle2), "contains(_:) Int")
    assert(arr.firstIndex(of: needle2) == 2, "firstIndex of Int")

    let missing: Int | String = 99
    assert(!arr.contains(missing), "contains missing should be false")
    assert(arr.firstIndex(of: missing) == nil, "firstIndex of missing")

    // Cross-leaf needle (Int 99) not equal to any String element
    assert(arr.firstIndex(of: missing) == nil, "Int needle never matches String element")
}

// MARK: 8. Array<NarrowedAny> direct equality
do {
    let a: [Int | String] = [1, "two", 3]
    let b: [Int | String] = [1, "two", 3]
    let c: [Int | String] = [1, "two", 4]
    assert(a == b, "Array<NarrowedAny> identical contents")
    assert(!(a == c), "Array<NarrowedAny> with one differing element")
}

// MARK: 9. Set<NarrowedAny> end-to-end (Hashable)
do {
    let a: Int | String = 5
    let b: Int | String = "hi"
    let c: Int | String = 5  // dedups with a
    let s = Set<Int | String>([a, b, c])
    assert(s.count == 2, "Set should deduplicate")
    assert(s.contains(a), "Set should contain a")
    assert(s.contains(b), "Set should contain b")
    assert(!s.contains(99 as (Int | String)),
           "Set should not contain unrelated value")
}

// MARK: 10. Dictionary<NarrowedAny, V> end-to-end (Hashable key)
do {
    let a: Int | String = 5
    let b: Int | String = "hi"
    let c: Int | String = 5  // overwrites a
    var d: [Int | String: String] = [:]
    d[a] = "alpha"
    d[b] = "beta"
    d[c] = "gamma"
    assert(d.count == 2, "Dict should have 2 keys after overwrite")
    assert(d[a] == "gamma", "a should hold the overwritten value")
    assert(d[b] == "beta")
}

// MARK: 11. Higher-order Array Equatable composition
do {
    let arr: [Int | String] = [1, "two", 3, "four", 5]

    // reduce — counts using Equatable comparison
    let needle: Int | String = "two"
    let count = arr.reduce(0) { $1 == needle ? $0 + 1 : $0 }
    assert(count == 1, "reduce should count one match")

    // map preserves types
    let mapped = arr.map { $0 }
    assert(mapped == arr, "Array.map identity preserves equality")

    // filter via Equatable
    let target: Int | String = 3
    let filtered = arr.filter { $0 == target }
    assert(filtered.count == 1, "filter should keep 1 element")
    assert(filtered.first == target, "filtered element matches target")
}

// MARK: 12. Tuple containing narrowed-Any (composes through tuple Equatable)
do {
    let t1: (Int | String, Int) = (1, 2)
    let t2: (Int | String, Int) = (1, 2)
    let t3: (Int | String, Int) = ("hi", 2)
    assert(t1 == t2, "tuple with same Int leaf equal")
    assert(!(t1 == t3), "tuple with different first-leaf type unequal")
}

// MARK: 12.5. Comparable per-leaf dispatch + cross-leaf declaration order
do {
    let a: Int | String = 5
    let b: Int | String = 7
    assert(a < b, "same-leaf Int 5 < 7")
    assert(!(b < a), "anti-symmetry")

    let s1: Int | String = "apple"
    let s2: Int | String = "banana"
    assert(s1 < s2, "same-leaf String alphabetical")

    // Cross-leaf: order follows declaration order in `Int | String`
    let i: Int | String = 5
    let s: Int | String = "hi"
    assert(i < s, "Int (decl idx 0) < String (decl idx 1)")
    assert(!(s < i), "anti-symmetry across leaves")

    // Strict total order — sort produces stable interleaving by leaf
    let arr: [Int | String] = [3, "z", 1, "a", 2, "b"]
    let sorted = arr.sorted()
    let intIndices = sorted.enumerated().compactMap { $0.element as? Int != nil ? $0.offset : nil }
    // All Ints come before all Strings
    assert(intIndices == [0, 1, 2], "all Ints sort before all Strings")
}

// MARK: 12.7. CustomStringConvertible per-leaf description dispatch
do {
    func describe<T: CustomStringConvertible>(_ x: T) -> String { x.description }

    let i: Int | String = 42
    assert(describe(i) == "42", "Int description")

    let s: Int | String = "hi"
    assert(describe(s) == "hi", "String description")

    // String interpolation indirectly uses description
    let interp = "v=\(i)"
    assert(interp == "v=42", "interpolation Int leaf")

    let interp2 = "v=\(s)"
    assert(interp2 == "v=hi", "interpolation String leaf")
}

// MARK: 12.8. Encodable per-leaf encode dispatch (untagged JSON)
import Foundation
do {
    let v1: Int | String = 42
    let v2: Int | String = "hello"

    let d1 = try JSONEncoder().encode(v1)
    let s1 = String(data: d1, encoding: .utf8)!
    assert(s1 == "42", "Int encoded untagged")

    let d2 = try JSONEncoder().encode(v2)
    let s2 = String(data: d2, encoding: .utf8)!
    assert(s2 == "\"hello\"", "String encoded untagged")

    // Array of narrowed-Any → JSON array with mixed leaf encoding
    let arr: [Int | String] = [1, "two", 3]
    let d3 = try JSONEncoder().encode(arr)
    let s3 = String(data: d3, encoding: .utf8)!
    assert(s3 == "[1,\"two\",3]", "Array<NarrowedAny> untagged JSON")
}

// MARK: 12.9. Decodable per-leaf init dispatch (untagged JSON, round-trip)
do {
    typealias U = Int | String

    let d1 = "42".data(using: .utf8)!
    let v1 = try JSONDecoder().decode(U.self, from: d1)
    if let i = v1 as? Int {
        assert(i == 42, "decoded Int leaf")
    } else { fatalError("expected Int leaf") }

    let d2 = "\"hello\"".data(using: .utf8)!
    let v2 = try JSONDecoder().decode(U.self, from: d2)
    if let s = v2 as? String {
        assert(s == "hello", "decoded String leaf")
    } else { fatalError("expected String leaf") }

    // Round-trip an array of narrowed-Any
    let arr: [U] = [1, "a", 2, "b"]
    let enc = try JSONEncoder().encode(arr)
    let dec = try JSONDecoder().decode([U].self, from: enc)
    assert(dec.count == 4, "roundtrip preserves count")
    if let first = dec.first as? Int {
        assert(first == 1, "first round-trip element")
    }
}

// MARK: 12.10. Codable struct embedding narrowed-Any (real-world JSON shape)
do {
    struct Container: Codable {
        let id: Int
        let value: Int | String
        let tags: [Int | String]
    }

    let c = Container(id: 1, value: "hello", tags: [1, "two", 3])
    let data = try JSONEncoder().encode(c)
    let s = String(data: data, encoding: .utf8)!
    // JSON dict ordering is unspecified, so only check substrings
    assert(s.contains("\"id\":1"), "id field encoded")
    assert(s.contains("\"value\":\"hello\""), "narrowed-Any String leaf encoded")
    assert(s.contains("\"tags\":[1,\"two\",3]"),
           "Array<NarrowedAny> field encoded")

    let decoded = try JSONDecoder().decode(Container.self, from: data)
    assert(decoded.id == 1)
    if let s = decoded.value as? String {
        assert(s == "hello", "decoded value String leaf")
    } else { fatalError("expected String leaf") }
    assert(decoded.tags.count == 3, "decoded tags array")
}

// MARK: 12.11. Optional<NarrowedAny> Codable round-trip
do {
    typealias U = Int | String
    let arr: [U?] = [1, nil, "x", nil]
    let data = try JSONEncoder().encode(arr)
    let s = String(data: data, encoding: .utf8)!
    assert(s == "[1,null,\"x\",null]", "Optional<NarrowedAny> JSON")
    let decoded = try JSONDecoder().decode([U?].self, from: data)
    assert(decoded.count == 4, "round-trip count")
    assert(decoded[1] == nil, "nil preserved")
    assert(decoded[3] == nil, "nil preserved")
}

// MARK: 12.12. Generic Hashable + Encodable wrappers
do {
    func uniqueCount<T: Hashable>(_ arr: [T]) -> Int { Set(arr).count }
    func toJSON<T: Encodable>(_ x: T) throws -> String {
        let data = try JSONEncoder().encode(x)
        return String(data: data, encoding: .utf8)!
    }
    let arr: [Int | String] = [1, 2, "a", 1, "a", 3]
    assert(uniqueCount(arr) == 4, "generic Hashable on narrowed-Any")
    let j1 = try toJSON(1 as (Int | String))
    assert(j1 == "1", "generic Encodable Int leaf")
    let j2 = try toJSON("x" as (Int | String))
    assert(j2 == "\"x\"", "generic Encodable String leaf")
}

// MARK: 13. Set membership through Hashable + Equatable
do {
    let s: Set<Int | String> = [1, 2, 3, "a", "b"]
    assert(s.count == 5, "Set with 5 distinct elements")
    let probe: Int | String = 2
    assert(s.contains(probe), "Set contains Int 2")
    let noProbe: Int | String = 99
    assert(!s.contains(noProbe), "Set does not contain unrelated Int")
    // Note: Set arithmetic ops (union/intersection/etc.) currently
    // crash because Set's internals route element-type conformance
    // lookup through the Any-singleton metadata, finding `Any:Hashable`
    // (doesn't exist) rather than our `Int|String:Hashable` builtin.
    // Tracked as a Phase-3 design follow-up.
}

// MARK: 13.5. == + Set<V>(arrayOfV) co-existence (slice 16: dedup PCD emit)
do {
    let a: Int | String = 1
    let b: Int | String = 1
    assert(a == b, "direct == still works")
    let arr: [Int | String] = [a, b, "x", "x", 2]
    let s = Set<Int | String>(arr)
    assert(s.count == 3, "Set<V>(arrayOfV) dedups to {1, \"x\", 2}")
    assert(s.contains(a), "Set<V>(arrayOfV) contains a")
    assert(s.contains("x" as (Int | String)), "Set<V>(arrayOfV) contains \"x\"")
}

// MARK: 13.55. Nested narrowed-Any with class leaves (slice 17 follow-up)
//
// Slice 17's conditional dest-destroy emitted destroyCall via SILType,
// which routed through metadata caching and triggered LLVM's "does
// not dominate all uses" verifier crash when the dest type was a
// nested narrowed-Any with class leaves. Follow-up uses the runtime
// metadata pointer already loaded for the leaf-membership check.
do {
    final class CB: Equatable {
        let id: Int
        init(_ id: Int) { self.id = id }
        static func == (a: CB, b: CB) -> Bool { a.id == b.id }
    }
    typealias Inner = String | Bool
    typealias V = CB | Inner
    let a: V = CB(1)
    let b: V = CB(1)
    assert(a == b, "value-equal class leaves compare equal through nested ==")
    let c: V = "hi"
    let d: V = "hi"
    assert(c == d, "string leaves through nested == compare equal")
    let e: V = true
    let f: V = false
    assert(!(e == f), "Bool leaves compare correctly through nested ==")
    assert(!(a == c), "cross-leaf class vs string compare false")
}

// MARK: 13.6. Non-leaf cast no-leak (slice 17: ref-count integrity)
//
// `x as? V` where x's static type is not in V's leaf set used to leak
// the value. swift_dynamicCast succeeded layout-wise (narrowed-Any
// reuses Any layout) and wrote x into dest's existential buffer, but
// slice-15's leaf-membership post-check then returned false, marking
// the cast failed without ever destroying the value already in dest.
// For class instances this manifested as a missing `deinit`. Slice 17
// short-circuits the call when the source is statically a non-leaf
// concrete type, and conditionally destroys dest's contents when the
// runtime check rejects a generic/existential source.
do {
    final class W {
        let id: Int
        let track: (Int) -> Void
        init(_ id: Int, _ track: @escaping (Int) -> Void) {
            self.id = id
            self.track = track
            track(id)        // alloc tracker
        }
        deinit { track(-id) } // free tracker
    }

    var allocs: [Int] = []
    func track(_ n: Int) { allocs.append(n) }

    // The direct `w as? (Int | String)` form is now a hard compile
    // error per decision row #18 (disjoint cast — Witness is not a
    // leaf of Int|String). The slice-17 ref-count integrity story
    // is now exercised through the generic path only, which still
    // routes through the runtime's leaf-membership post-check
    // (Sema can't statically prove disjointness for a generic T).
    allocs.removeAll()
    func tryCast<T>(_ x: T) -> (Int | String)? {
        return x as? (Int | String)
    }
    do {
        let w = W(2, track)
        let v = tryCast(w)
        assert(v == nil, "Witness is not a leaf via generic")
    }
    assert(allocs == [2, -2], "non-leaf generic copy_on_success must release dest copy")
}

// MARK: 13.7. Wider-to-narrower narrowed-Any cast (slice 17 dynamic-source path)
//
// `let v: A|B|C = ...; v as? (A|B)` exercises the post-check's
// dynamic-source code path: swift_dynamicCast layout-matches (Any to
// Any), then the leaf-membership check on dest's runtime metadata
// rejects values whose dynamic type is C. For class leaves, slice 17's
// conditional destroy must release the dest copy when the runtime
// rejects.
do {
    final class A: Equatable {
        let id: Int
        init(_ id: Int) { self.id = id }
        static func == (a: A, b: A) -> Bool { a.id == b.id }
    }
    typealias Wider = A | String | Bool
    typealias Narrower = A | String

    do {
        let v: Wider = A(1)
        let u: Narrower? = v as? Narrower
        assert(u != nil, "A is in Narrower")
    }
    do {
        let v: Wider = "x"
        let u: Narrower? = v as? Narrower
        assert(u != nil, "String is in Narrower")
    }
    do {
        let v: Wider = true
        let u: Narrower? = v as? Narrower
        assert(u == nil, "Bool is not in Narrower")
    }
    // Loop with mixed dynamic types — exercises the post-check on
    // each iteration including the destroy path.
    let arr: [Wider] = [A(2), "y", true, A(3), false]
    let us = arr.compactMap { $0 as? Narrower }
    assert(us.count == 3, "compactMap drops the two Bool elements")
}

// MARK: 13.8. Hard error for disjoint `as?` / `as!`; warning for `is`
// (decision row #18, lifted 2026-05-03 from slice-18's original warning
// posture). The closed leaf set makes "no type in common" a static
// fact, not a runtime question, so `v as? T` / `v as! T` against a
// concrete T with no overlap with V's leaves are rejected at compile
// time. `v is T` keeps the warning posture, matching Swift's existing
// convention for statically-false `is` expressions.
//
// The disjoint cases below would be compile errors and are gated out
// of the runnable test bed. The `is` form stays warning + runtime
// false. (Pattern-form disjoint cast in §13.9 is also commented out
// for the same reason.)
do {
    typealias V = Int | String
    let v: V = 42
    // let b:   Bool? = v as? Bool   // ⛔ error: Bool is not in V's leaf set
    // let f:   Bool  = v as! Bool   // ⛔ error: same disjoint check
    let isB: Bool = v is Bool         // ⚠ warning, runtime false
    assert(!isB, "Bool is-check statically and dynamically false")
}

// MARK: 13.9. Pattern-cast against a non-leaf type (decision row #18)
//
// `case let _ as T` against a narrowed-Any subject is the pattern-form
// twin of §13.8's `as?`. After row #18, a disjoint pattern arm is a
// compile error (the arm is provably dead). The disjoint pattern is
// gated out of the runnable test bed; the in-leaf arms still
// exercise the matching machinery.
do {
    typealias V = Int | String
    var hits = 0
    let v: V = "yo"
    switch v {
    case let i as Int: hits += i
    case let s as String: hits += s.count
    // case let b as Bool: hits += b ? 100 : -100  // ⛔ error: dead arm
    }
    assert(hits == 2, "string \"yo\" matched the String arm")

    // if-let pattern with disjoint target is also an error now:
    //   if let _ = v as? Bool { … }                // ⛔ error
}

// MARK: 13.10. Direction-B disjoint cast: concrete non-leaf → narrowed-Any
// (decision row #18 mirror). Same flip — `as?`/`as!` is now a hard
// error, leaving slice 17's IRGen short-circuit as defence-in-depth
// for non-source paths.
do {
    typealias V = Int | String
    _ = V.self                         // silence unused-typealias
    // let b = true
    // let r: V? = b as? V             // ⛔ error: Bool is not in V's leaf set
}

// MARK: 13.105. Widening narrowed-Any cast always-succeeds (slice 18 widening-check)
//
// `v as? W` where v: V = Int|String and W = Int|String|Bool — every
// leaf of V is in W's leaf set, so the cast always succeeds. Sema
// suggests using `as` (coercion) instead of `as?`.
do {
    typealias V = Int | String
    typealias W = Int | String | Bool
    let v: V = 42
    // Compile-time: warns "always succeeds; consider using 'as'"
    // Runtime: cast indeed succeeds.
    let w: W? = v as? W
    assert(w != nil, "V→W widening cast always succeeds at runtime too")
    let isW: Bool = v is W
    assert(isW, "V→W is-check always evaluates to true")
}

// MARK: 13.108. Nested narrowed-Any deep-leaf comparison (slice 23)
//
// `W = V | Bool` where `V = Int | String`. The slice-18 leaf check
// initially compared surface alternatives only — for `W`'s alts
// `[V, Bool]` the comparison missed that `Int`/`String`/`V` are all
// reachable deep leaves and false-positived as "disjoint" or
// "always returns nil". Slice 23 makes the helper recurse: deep
// leaves of `W` = {Int, String, Bool}; deep leaves of `V` =
// {Int, String}.
do {
    typealias V = Int | String
    typealias W = V | Bool
    let w: W = 1
    // Int IS a deep leaf of W (via V). Should NOT warn.
    let i: Int? = w as? Int
    assert(i == 1, "W → Int succeeds when w holds an Int")

    // V IS a direct leaf of W. Should NOT warn (partial overlap —
    // succeeds when w holds Int/String, fails when w holds Bool).
    let v: V? = w as? V
    assert(v as? Int == 1, "W → V succeeds when w holds Int via V leaf")

    let wBool: W = true
    let v2: V? = wBool as? V
    assert(v2 == nil, "W → V fails when w holds Bool")

    // V → W: every V leaf is in W's deep leaf set, so the legacy
    // "always succeeds" fires (V→W is a static upcast). Slice 23
    // suppresses the slice-18 widening note in this case to avoid
    // duplicate diagnostics.
    let vSrc: V = 42
    let wTgt: W? = vSrc as? W
    assert(wTgt.flatMap { $0 as? Int } == 42,
           "V → W widening preserves value")
}

// MARK: 13.11. Disjoint narrowed-Any → narrowed-Any cast (decision row #18)
//
// `v as? W` where v: V and V/W are narrowed-Any with disjoint leaf
// sets. Per row #18 this is a hard error — gated out of the runnable
// test bed. Slice 17's runtime post-check still defends against any
// path that bypasses Sema (specialisation / generic widening / etc.)
do {
    typealias V = Int | String
    typealias W = Bool | Float
    _ = (V.self, W.self)
    // let v: V = 42
    // let w: W? = v as? W              // ⛔ error: leaf sets disjoint
}

// §13.12 — Codable round-trip preserves nested-narrowed-Any membership
// (slice 24) — see test-phase3f-codable-nested.swift. Pulled out of this
// file because the cumulative witness-table state when run through JIT
// interpret-mode pushes Foundation's JSONWriter into a stale-optional
// fatalError; compile-then-run works end-to-end.

// MARK: 13.13. Literal default rebinds to a leaf when narrowed-Any is the
// contextual type (slice 25)
//
// Before slice 25: `let arr: [Int | String | Float] = [1, "a", 2.5]`
// errored with "cannot convert value of type 'Double' to expected element
// type 'X' (aka 'any Int | String | Float')". The float literal `2.5`
// defaulted to its stdlib type Double, which isn't in X's closed leaf
// set, and the solver never tried Float (which IS a leaf and IS
// ExpressibleByFloatLiteral). Same shape for integer literals when the
// default type Int isn't a leaf.
//
// Fix: when a relational constraint suggests a narrowed-Any as the upper
// bound for a type variable, also offer each leaf as a candidate
// binding. The solver then picks the first leaf that satisfies the
// type variable's other constraints (the literal protocol).
do {
    typealias X = Int | String | Float
    let arr: [X] = [1, "a", 2.5]
    var saw = (i: false, s: false, f: false)
    for x in arr {
        if let _ = x as? Int { saw.i = true }
        else if let _ = x as? String { saw.s = true }
        else if let _ = x as? Float { saw.f = true }
    }
    assert(saw.i && saw.s && saw.f,
           "literals bind to Int/String/Float leaves of X")
}

do {
    // Y has no Int leaf — `1` should rebind to Float (Float conforms to
    // ExpressibleByIntegerLiteral), not produce a "cannot convert Int"
    // error.
    typealias Y = String | Float
    let arr: [Y] = [1, "a", 2.5]
    let floats: [Float] = arr.compactMap { $0 as? Float }
    assert(floats.count == 2, "1 and 2.5 both rebind to Float when Int isn't a leaf")
}

do {
    // 3-deep: deep-leaf candidates matter. Direct leaves of X are
    // {W, Float}, but neither W nor Float matches the integer-literal
    // protocol *and* sits at the same level as Int. Without recursing,
    // the solver would jump straight to Float for `1` (Float conforms
    // to ExpressibleByIntegerLiteral). Adding deep leaves surfaces
    // Int as a candidate so `1` correctly binds to Int.
    typealias V = Int | String
    typealias W = V | Bool
    typealias X = W | Float
    let xs: [X] = [1, "a", true, 2.5]
    var kinds: [String] = []
    for x in xs {
        if let _ = x as? Int { kinds.append("Int") }
        else if let _ = x as? String { kinds.append("String") }
        else if let _ = x as? Bool { kinds.append("Bool") }
        else if let _ = x as? Float { kinds.append("Float") }
        else { kinds.append("?") }
    }
    assert(kinds == ["Int", "String", "Bool", "Float"],
           "3-deep narrowed-Any picks the right deep leaf for each literal")
}

// MARK: 13.14. Class-hierarchy casts (slice 29)
//
// Slice 18's leaf-membership check originally used canonical equality
// only, which treated every class-hierarchy cast as "always fails":
// V = Dog | Cat → Animal (upcast) and Animal → V (downcast where the
// dynamic class is a leaf) both got flagged at compile time and the
// runtime returned nil.
//
// Slice 29 walks `isExactSuperclassOf` in both directions at the Sema
// layer to silence the false-positive warning, and at IRGen extends
// the post-check to load the dynamic class from the heap object's
// first word (existential metadata slot stores the *static* src type
// for class-into-Any boxing, not the dynamic class).
do {
    class Animal { let name: String; init(_ n: String) { name = n } }
    class Dog: Animal {}
    class Cat: Animal {}
    typealias V = Dog | Cat

    // Upcast: V → Animal — every leaf IS-A Animal. The runtime cast
    // unwraps V's existential and the dynamic Dog or Cat IS-A Animal.
    let d: V = Dog("rex")
    let a1: Animal? = d as? Animal
    assert(a1?.name == "rex", "V → Animal upcast preserves leaf instance")
    assert((d as! Animal).name == "rex", "V → Animal force-cast also works")

    // Downcast: Animal → V where Animal holds a Dog at runtime. With
    // slice 29 IRGen, the post-check finds the leaf via the heap
    // object's class metadata even though the existential's metadata
    // slot stores Animal.self for class boxing.
    let a: Animal = Dog("buddy")
    let v: V? = a as? V
    assert(v != nil, "Animal-bound Dog → V finds the dynamic Dog leaf")
    assert((v as? Dog)?.name == "buddy",
           "decoded leaf flows through V correctly")

    // Negative: an unrelated Animal (not a leaf subclass) → V should
    // still return nil so the closed leaf set is honored.
    let plain: Animal = Animal("plain")
    let v2: V? = plain as? V
    assert(v2 == nil, "plain Animal (not in {Dog, Cat}) → V is nil")

    // Subclass-of-leaf: Puppy: Dog. The runtime cast should find Dog
    // via the superclass walk. emitClassDowncast (used in slice 29's
    // follow-up) handles this; bare metadata equality wouldn't.
    class Puppy: Dog { let age: Int; init(_ n: String, _ a: Int) { age = a; super.init(n) } }
    let pup: Animal = Puppy("rex", 2)
    let vp: V? = pup as? V
    assert(vp != nil, "subclass of leaf flows through V")
    assert((vp as? Dog)?.name == "rex",
           "Puppy reaches Dog leaf and round-trips back to Dog")
}

// MARK: 13.15. KeyPath into a narrowed-Any field works at runtime (slice 31)
//
// Pre-slice-31 the runtime aborted with `Fatal: could not demangle
// keypath type from 'Si_SSXN'` because the system stdlib's lazy
// demangle path didn't recognize the `XN` operator. Slice 31
// substitutes Any for narrowed-Any in the keypath's recorded
// type-ref so the runtime sees a type it can decode.
do {
    typealias V = Int | String
    struct Holder { var v: V }
    var h = Holder(v: 1)
    let kp = \Holder.v
    assert((h[keyPath: kp] as? Int) == 1,
           "read keypath into narrowed-Any field")
    let wkp: WritableKeyPath<Holder, V> = \Holder.v
    h[keyPath: wkp] = "changed"
    assert((h[keyPath: wkp] as? String) == "changed",
           "write through writable keypath")
}

// MARK: 13.16. Mirror reflection of a narrowed-Any field (slice 32)
//
// Pre-slice-32 Mirror printed 'unable to demangle the type of
// field. the mangled type name is "Si_SSXN"' and showed the field
// as an empty tuple. Slice 32 routes the type-ref through
// getTypeRefByFunction so the runtime never tries to demangle
// `XN`; reflection sees the actual value.
do {
    typealias V = Int | String
    struct Container { var v: V; var w: [V] }
    let c = Container(v: 42, w: ["a", 1, "b"])
    let m = Mirror(reflecting: c)
    var sawV = false
    var sawW = false
    for child in m.children {
        if child.label == "v" {
            // The reflected value should be the actual Int 42, not
            // an empty tuple `()`.
            if let i = child.value as? Int, i == 42 { sawV = true }
        }
        if child.label == "w" {
            if let arr = child.value as? [Any], arr.count == 3 { sawW = true }
        }
    }
    assert(sawV, "Mirror reads narrowed-Any scalar field correctly")
    assert(sawW, "Mirror reads [narrowed-Any] field correctly")
}

// MARK: 13.17. Tuple-shaped leaves accept either form (slice 34)
//
// Pre-slice-34 the leaf-iteration in matchExistentialTypes
// committed to the first tuple alternative whenever
// matchTupleTypes returned success-without-fixes — even if the
// element-wise constraints would later fail. So
// `(Int, String) | (String, Int) = ("hi", 7)` reported
// "cannot convert value of type '(String, Int)' to specified
// type '(Int, String)'" because matchTypes locked in the
// (Int, String) leaf and never tried (String, Int).
//
// Slice 34 generates a real disjunction over the tuple-shaped
// alternatives so the solver backtracks. Pre-typed tuple values
// kept working (canonical equality already routed them through
// the structural-leaf check); literal tuple expressions now also
// pick the right leaf.
do {
    typealias TwoShape = (Int, String) | (String, Int)

    let a: TwoShape = (7, "hi")    // matches first leaf
    let b: TwoShape = ("hi", 7)    // matches second leaf

    if case let (i, s) as (Int, String) = a {
        assert(i == 7 && s == "hi", "first leaf round-trips")
    } else {
        assertionFailure("a should match (Int, String)")
    }
    if case let (s, i) as (String, Int) = b {
        assert(s == "hi" && i == 7, "second leaf round-trips")
    } else {
        assertionFailure("b should match (String, Int)")
    }

    // Three-leaf disambiguation
    typealias ThreeShape = (Int, Int) | (String, String) | (Int, String)
    let m: ThreeShape = (1, "x")   // (Int, String) — only matching shape
    let n: ThreeShape = ("a", "b") // (String, String)
    let o: ThreeShape = (1, 2)     // (Int, Int)

    if case let pair as (Int, String) = m {
        assert(pair == (1, "x"), "mixed tuple picks (Int, String)")
    } else { assertionFailure("m should be (Int, String)") }
    if case let pair as (String, String) = n {
        assert(pair == ("a", "b"), "string tuple picks (String, String)")
    } else { assertionFailure("n should be (String, String)") }
    if case let pair as (Int, Int) = o {
        assert(pair == (1, 2), "int tuple picks (Int, Int)")
    } else { assertionFailure("o should be (Int, Int)") }

    // Mixed tuple+non-tuple alternatives still work
    typealias MixedShape = (Int, String) | Bool
    let p: MixedShape = (1, "x")
    let q: MixedShape = true
    if case let pair as (Int, String) = p {
        assert(pair == (1, "x"), "mixed: tuple side")
    } else { assertionFailure("p should be (Int, String)") }
    if case let v as Bool = q {
        assert(v == true, "mixed: bool side")
    } else { assertionFailure("q should be Bool") }
}

// MARK: 13.18. Enum-leaf case dispatch (slice 35)
//
// Pre-slice-35 the SpaceEngine's isSubspace(Constructor, Type)
// always returned true ("typechecking guaranteed it's a subspace"),
// so writing `case .red` after `case let i as Int` over a
// narrowed-Any subject produced a noisy "case is already handled"
// warning. Fixing the SpaceEngine surfaced a SILGen crash because
// emitEnumElementDispatch hard-coded the assumption that the
// subject is an enum, which a narrowed-Any subject isn't (it
// reuses Any layout).
//
// Slice 35 lands both halves: SpaceEngine recognizes the
// constructor-vs-type comparison correctly, and SILGen pre-casts
// narrowed-Any to the enum leaf via alloc_stack +
// checked_cast_addr_br + load before running the standard enum
// dispatch. EnumElementPattern types are rewritten from the
// narrowed-Any subject to the enum leaf so CaseBlocks derives
// the right enumDecl.
do {
    enum Color { case red, green, blue }
    typealias V = Color | Int

    func handle(_ v: V) -> String {
        switch v {
        case let i as Int: return "int \(i)"
        case .red:         return "red"
        case .green:       return "green"
        case .blue:        return "blue"
        }
    }

    assert(handle(7) == "int 7", "Int leaf")
    assert(handle(.red) == "red", ".red dispatch")
    assert(handle(.green) == "green", ".green dispatch")
    assert(handle(.blue) == "blue", ".blue dispatch")

    // Enum with associated values (payload)
    enum Kind { case num(Int), name(String) }
    typealias W = Kind | Bool
    func handle2(_ w: W) -> String {
        switch w {
        case let b as Bool:    return "bool \(b)"
        case .num(let n):      return "num \(n)"
        case .name(let s):     return "name \(s)"
        }
    }
    assert(handle2(true) == "bool true", "Bool leaf in W")
    assert(handle2(.num(42)) == "num 42", "payload .num extracted")
    assert(handle2(.name("x")) == "name x", "payload .name extracted")

    // Default arm covers uncovered cases
    func handle3(_ v: V) -> String {
        switch v {
        case let i as Int: return "int \(i)"
        case .red:         return "red"
        default:           return "other"
        }
    }
    assert(handle3(.red) == "red", "covered case")
    assert(handle3(.blue) == "other", "default catches uncovered enum case")
    assert(handle3(7) == "int 7", "default doesn't shadow Int leaf")

    // Multiple enum leaves — narrowed-Any spans Color and Direction
    enum Direction { case left, right }
    typealias CD = Color | Direction
    func handle4(_ v: CD) -> String {
        switch v {
        case .red:    return "red"
        case .green:  return "green"
        case .blue:   return "blue"
        case .left:   return "left"
        case .right:  return "right"
        }
    }
    let cases: [(CD, String)] = [
        (.red, "red"), (.green, "green"), (.blue, "blue"),
        (.left, "left"), (.right, "right"),
    ]
    for (v, expected) in cases {
        assert(handle4(v) == expected,
               "multi-enum dispatch: expected \(expected) got \(handle4(v))")
    }
}

// MARK: 13.19. Subclass-into-narrowed-Any with enum + class leaves
//
// Pre-fix: `let v: Color | Animal = Dog()` (Dog: Animal) reported
// "failed to produce diagnostic for expression". The
// matchExistentialTypes fallback's per-alt matchTypes trial leaves
// residue when an unrelated enum leaf (Color) is tried first,
// preventing the Animal alt from cleanly succeeding via the
// standard subtype lattice. Animal | String + Dog worked because
// no enum leaf was present to interfere.
//
// Fix: catch class-subtype-of-leaf in the structural-leaf check
// upstream of the fallback. Dog ≤ Animal short-circuits to
// success without ever attempting the Color leaf.
do {
    enum Color { case red, green }
    class Animal { var name: String { "Animal" } }
    class Dog: Animal { override var name: String { "Dog" } }
    typealias V = Color | Animal

    func handle(_ v: V) -> String {
        switch v {
        case .red:               return "red"
        case .green:             return "green"
        case let a as Animal:    return a.name
        }
    }

    assert(handle(.red) == "red", "enum leaf direct")
    assert(handle(Animal()) == "Animal", "class leaf direct")
    assert(handle(Dog()) == "Dog", "subclass injects through class leaf")
}

// MARK: 13.20. Nested narrowed-Any with enum dispatch (slice 35 + 23)
//
// Slice 35's pre-cast machinery composes with slice 23's deep-leaf
// cast feasibility: an inner narrowed-Any with an enum leaf can be
// projected from an outer narrowed-Any via `case let inner as Inner`
// then nested-switched to the enum cases.
do {
    enum Color { case red, green }
    typealias Inner = Color | Int
    typealias Outer = Inner | String

    func handle(_ v: Outer) -> String {
        switch v {
        case let s as String:
            return "str \(s)"
        case let inner as Inner:
            switch inner {
            case .red:           return "red"
            case .green:         return "green"
            case let i as Int:   return "int \(i)"
            }
        }
    }

    assert(handle("hi") == "str hi", "outer String leaf")
    assert(handle(7 as Inner) == "int 7", "inner Int leaf via projection")
    assert(handle(.red as Inner) == "red", "inner Color.red via projection")
    assert(handle(.green as Inner) == "green", "inner Color.green via projection")
}

// MARK: 13.21. Enum leaves compose with route-1 protocol synthesis
//
// Verifies that slice 6/7/11 (Equatable / Hashable / Comparable
// per-leaf dispatch) composes with enum leaves: when a narrowed-Any
// has an enum that conforms to a protocol, dispatching that
// protocol's witnesses through the narrowed-Any value uses the
// enum's own conformance correctly.
do {
    enum Color: Hashable, Comparable { case red, green, blue }
    typealias V = Color | Int

    // Equatable
    let r1: V = .red
    let r2: V = .red
    let g: V = .green
    let i: V = 42
    assert(r1 == r2, "same enum case: equal")
    assert(!(r1 == g), "different enum cases of same leaf: not equal")
    assert(!(r1 == i), "different leaves: not equal")

    // Hashable (Set dedup)
    let s = Set<V>([r1, r2, g, i, .blue, 100])
    assert(s.count == 5,
           "Set dedup: red+red merge → 5 unique (red, green, blue, 42, 100), got \(s.count)")

    // Comparable (declaration-order cross-leaf, within-leaf by leaf's <)
    let arr: [V] = [42, .red, .green, 7, .blue]
    let sorted = arr.sorted()
    let strs = sorted.map { v -> String in
        if let c = v as? Color {
            switch c { case .red: return "red"; case .green: return "green"; case .blue: return "blue" }
        }
        if let n = v as? Int { return "\(n)" }
        return "?"
    }
    assert(strs == ["red", "green", "blue", "7", "42"],
           "Comparable cross-leaf: Color leaf first (decl order), then Int (numeric); got \(strs)")
}

// MARK: 13.22. Top-level catch-arm enum-case dispatch (slice 36)
//
// Slice 3.D recognizes do-catch as exhaustive when each declared
// alternative has a `catch let _ as Alt:` clause (IsPattern). When
// each enum leaf's *cases* are fully covered by EnumElementPatterns
// at the top level, slice 36 also accepts that as exhaustive — so
// `throws(NetErr | DecodeErr)` with cross-domain top-level catch
// arms compiles directly without nesting.
do {
    enum NetErr: Error { case timeout, badResponse(Int) }
    enum DecodeErr: Error { case malformed, missingKey(String) }

    func fetch(_ which: Int) throws(NetErr | DecodeErr) -> String {
        switch which {
        case 0: throw NetErr.timeout
        case 1: throw NetErr.badResponse(503)
        case 2: throw DecodeErr.malformed
        case 3: throw DecodeErr.missingKey("user")
        default: return "ok"
        }
    }

    func describe(_ w: Int) -> String {
        do {
            return "ok:\(try fetch(w))"
        } catch .timeout {
            return "net.timeout"
        } catch .badResponse(let c) {
            return "net.bad(\(c))"
        } catch .malformed {
            return "dec.malformed"
        } catch .missingKey(let k) {
            return "dec.missing(\(k))"
        }
    }

    assert(describe(0) == "net.timeout", "case .timeout from NetErr")
    assert(describe(1) == "net.bad(503)", "case .badResponse(payload) from NetErr")
    assert(describe(2) == "dec.malformed", "case .malformed from DecodeErr")
    assert(describe(3) == "dec.missing(user)", "case .missingKey(payload) from DecodeErr")
    assert(describe(99) == "ok:ok", "non-throwing path")
}

// MARK: 13.23. Slice 36 — catch arms with where-guards + mixed-shape leaves
//
// Slice 36's exhaustiveness skips guarded patterns (they don't
// contribute to exhaustive coverage), so the unguarded patterns
// must still cover every leaf. Verify this composes with payload
// extraction, where-guards, and IsPattern coverage on a class
// leaf.
do {
    enum HTTPErr: Error { case status(Int), timeout }
    struct ConfigErr: Error { let msg: String }
    typealias E = HTTPErr | ConfigErr

    func fetch(_ kind: Int) throws(E) -> String {
        switch kind {
        case 0: throw HTTPErr.status(404)
        case 1: throw HTTPErr.status(500)
        case 2: throw HTTPErr.timeout
        case 3: throw ConfigErr(msg: "missing key")
        default: return "ok"
        }
    }

    func describe(_ k: Int) -> String {
        do {
            return "ok:\(try fetch(k))"
        } catch .status(let c) where c >= 500 {
            return "server-error \(c)"
        } catch .status(let c) {
            return "client-error \(c)"
        } catch .timeout {
            return "timed out"
        } catch let e as ConfigErr {
            return "config: \(e.msg)"
        }
    }

    assert(describe(0) == "client-error 404", "guard-fail falls through to unguarded .status(c)")
    assert(describe(1) == "server-error 500", "where-guard fires for c >= 500")
    assert(describe(2) == "timed out", "non-payload enum case")
    assert(describe(3) == "config: missing key", "IsPattern catch on class leaf")
    assert(describe(99) == "ok:ok", "non-throwing path")
}

// MARK: 13.24. Slice 35 + 23 — deep-leaf enum-case dispatch through nested narrowed-Any
//
// Slice 35's pre-cast composes with slice 23's deep-leaf machinery
// to let users write per-deep-leaf cases at the top level over a
// nested narrowed-Any subject. For `Outer = Inner | String`,
// `Inner = Color | Int`, the user can directly write:
//
//   switch v: Outer {
//     case let s as String:  …
//     case .red:             …    // Color.red — Inner's enum case
//     case .green:           …    // Color.green
//     case let i as Int:     …    // Inner's Int leaf
//   }
//
// without needing the explicit `case let inner as Inner: switch
// inner { … }` projection. swift_dynamicCast walks Outer's leaf
// set + deep leaves to find Color via Inner; slice 23's deep-leaf
// post-check confirms membership; slice 35's pre-cast retypes the
// SIL buffer to Color and runs the standard enum dispatch on the
// success block.
do {
    enum Color { case red, green }
    typealias Inner = Color | Int
    typealias Outer = Inner | String

    func handle(_ v: Outer) -> String {
        switch v {
        case let s as String:    return "str \(s)"
        case .red:               return "deep red"
        case .green:             return "deep green"
        case let i as Int:       return "deep int \(i)"
        }
    }

    assert(handle("hi") == "str hi", "outer String leaf")
    assert(handle(.red as Inner) == "deep red", "deep .red via Inner")
    assert(handle(.green as Inner) == "deep green", "deep .green via Inner")
    assert(handle(7 as Inner) == "deep int 7", "deep Int via Inner")
}

// MARK: 13.25. Slice 35 + 36 — cross-enum typed throws, all leaves caught
//
// Slice 35's enum-case pre-cast and slice 36's catch-arm
// exhaustiveness extension cooperate when a SE-0413 typed-throws
// signature spans **two distinct leaf enums**. A function declared
// `throws(NetErr | DecodeErr)` lets the caller catch every
// individual case across both enums at the top level:
//
//   func fetch(…) throws(NetErr | DecodeErr) -> String { … }
//
//   do {
//     return try fetch(k)
//   } catch .timeout            { … }   // NetErr leaf
//   catch .badResponse(let c)   { … }   // NetErr leaf w/ payload
//   catch .malformed            { … }   // DecodeErr leaf
//
// Slice 36 sees the union of {NetErr.timeout, .badResponse} ∪
// {DecodeErr.malformed} fully covers both leaves and declares the
// catch syntactically exhaustive — the enclosing `describe` need
// not re-throw, default, or itself be marked `throws`. Slice 35's
// dispatch partitions the catch arms by parent enum and chains
// `swift_dynamicCast` attempts so the right arm wins regardless of
// which leaf the runtime payload belongs to.
//
// (We've also corroborated this composes with `async`: a parallel
// /tmp/test_async_throws.swift wrapping the same shape in
// `async throws(NetErr | DecodeErr)` plus a `try await` catch-site
// runs end-to-end and prints all four expected strings. The await
// suspension boundary is invisible to slice 35/36's machinery.)
do {
    enum NetErr: Error { case timeout, badResponse(Int) }
    enum DecodeErr: Error { case malformed }

    func fetch(_ kind: Int) throws(NetErr | DecodeErr) -> String {
        switch kind {
        case 0: throw NetErr.timeout
        case 1: throw NetErr.badResponse(503)
        case 2: throw DecodeErr.malformed
        default: return "ok"
        }
    }

    func describe(_ k: Int) -> String {
        do {
            return "ok:\(try fetch(k))"
        } catch .timeout                { return "net.timeout" }
        catch .badResponse(let c)       { return "net.bad(\(c))" }
        catch .malformed                { return "dec.malformed" }
    }

    assert(describe(0) == "net.timeout", "cross-enum: NetErr.timeout caught")
    assert(describe(1) == "net.bad(503)", "cross-enum: NetErr.badResponse(_) caught")
    assert(describe(2) == "dec.malformed", "cross-enum: DecodeErr.malformed caught")
    assert(describe(3) == "ok:ok", "cross-enum: non-throwing path")
}

// MARK: 13.26. Slice 37 — slice 35/36 inside a rethrowing scope
//
// The catch-arm dispatch over a narrowed-Any error must work when the
// enclosing scope itself rethrows (an outer `throws` function or
// top-level / `@main` synthesised main). Pre-slice-37 SILGen emitted
// dangling `dealloc_stack` instructions in each catch arm's exit
// branch for the rethrow rewrap buffers (`alloc_existential_box $any
// Error`) — buffers that were allocated only on the all-leaves-fail
// path, but whose cleanups were registered at a depth above slice
// 35's per-leaf scopes. The arm bodies emitted dealloc_stack for
// allocations that weren't reachable on their path, tripping the SIL
// verifier's "deallocating allocation that is not the top of the
// stack" rule. Slice 37 wraps the failure handler in
// `emitCatchDispatch` with a `Scope` so emitThrow's cleanup
// registrations stay local to the rethrow path.
//
// The fixture exercises the "outer function rethrows" half of the
// trigger — top-level / @main script-mode is verified separately
// by /tmp/test_async_throws.swift's `do { try await … }` driver.
do {
    enum Side: Error { case left(Int), right(Int) }
    enum Mood: Error { case happy, sad }

    func dispatch(_ k: Int) throws(Side | Mood) -> String {
        switch k {
        case 0: throw Side.left(7)
        case 1: throw Side.right(8)
        case 2: throw Mood.happy
        default: throw Mood.sad
        }
    }

    // Outer function declares untyped `throws`, so the catch dispatch
    // must rewrap any unmatched narrowed-Any error to `any Error`.
    // With the where-guard on .left(let n) where n > 5 + an
    // unguarded .left(let n) catch-all, the chain has multiple arms
    // per leaf — the most stressful slice 35/36 layout.
    func describe(_ k: Int) throws -> String {
        do {
            return "ok:\(try dispatch(k))"
        } catch .left(let n) where n > 5 { return "L>\(n)" }
        catch .left(let n)               { return "L=\(n)" }
        catch .right(let n)              { return "R=\(n)" }
        catch .happy                     { return "H" }
        catch .sad                       { return "S" }
    }

    let r0 = try! describe(0)
    let r1 = try! describe(1)
    let r2 = try! describe(2)
    let r3 = try! describe(3)
    assert(r0 == "L>7", "where-guard fires on Side.left(7)")
    assert(r1 == "R=8", "Side.right(8) on unguarded arm")
    assert(r2 == "H",   "Mood.happy on unguarded arm")
    assert(r3 == "S",   "Mood.sad on unguarded arm")
}

// MARK: 13.27. Slice 38 — narrowed-Any survives -O SILOptimizer
//
// Two -O passes used to crash on narrowed-Any input:
//
//   * `ExistentialSpecializer::findConcreteTypeFromSoleConformingType`
//     ran `dyn_cast<ProtocolDecl>(constraint->getAnyNominal())` on a
//     `NarrowedAnyType` after peeling `ExistentialType`. NarrowedAny
//     has no nominal decl, so `getAnyNominal()` returned null and
//     `dyn_cast` (not `dyn_cast_or_null`) asserted. Slice 38 short-
//     circuits NarrowedAnyType in that helper — narrowed-Any has no
//     "sole conforming type" by design.
//
//   * `ProtocolConformance::getAssociatedConformance` for a
//     `BuiltinProtocolConformance` of flavor NarrowedAnyDispatch hit
//     the default header `unreachable("builtin-conformances never
//     have associated types")` whenever the SIL specializer asked
//     for e.g. Hashable's `Self: Equatable` refinement. Slice 38
//     intercepts in the .cpp dispatch wrapper and synthesises a
//     sibling NarrowedAnyDispatch for the requested associated
//     protocol — Hashable's refinement of Equatable is exactly the
//     pair that slice 8 already wired up.
//
// Both bugs were invisible at -Onone (the failing passes don't run)
// and only surfaced when test.sh gained stage 6 (`-O -emit-sil`). The
// runtime fixture below uses a `Set<Color | Int>` populated through
// the generic `Set.init<S: Sequence>(_:)` and stressed via
// `.contains` / `.count` — the same call path that GenericSpecializer
// tries to specialize, exercising the Hashable→Equatable refinement
// at runtime. The fixture passes equally at -Onone and -O after the
// fix; before, -O crashed in pipeline pass #29503 (GenericSpecializer
// on Set's init) and pass #15498 (ExistentialSpecializer on map).
do {
    enum Color: Int { case red = 1, green = 2, blue = 3 }
    typealias V = Color | Int

    let xs: [V] = [.red, 7, .green, 7, .red, 11]
    let s: Set<V> = Set(xs)
    // Set semantics: duplicates de-duplicated by per-leaf Hashable.
    assert(s.count == 4, "Set<V> de-dup: {.red, 7, .green, 11}")
    assert(s.contains(.red as V), "Set<V> contains Color.red")
    assert(s.contains(7 as V), "Set<V> contains Int 7")
    assert(s.contains(11 as V), "Set<V> contains Int 11")
    assert(!s.contains(.blue as V), "Set<V> excludes Color.blue")
    assert(!s.contains(99 as V), "Set<V> excludes Int 99")

    // Force GenericSpecializer to monomorphize Array.map<V, U> with
    // the narrowed-Any element + a closure returning narrowed-Any
    // (the ExistentialSpecializer crash path).
    let labels: [String] = xs.map { v in
        switch v {
        case let i as Int: return "i\(i)"
        case let c as Color: return "c\(c.rawValue)"
        }
    }
    assert(labels == ["c1", "i7", "c2", "i7", "c1", "i11"],
           "Array<V>.map produces per-leaf labels")
}
