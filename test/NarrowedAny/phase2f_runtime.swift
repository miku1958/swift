// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Runtime semantics that became testable once the Phase 2b.D resolution
// flip landed: variance in containers, marker-protocol propagation
// (Sendable), and end-to-end multi-source typed throws.

import Foundation

// MARK: 1. Element-wise leaf injection through generic positions
// `[Int]` assigned to `[Int | String]` works element-by-element through
// the leaf-injection rule. Runtime layout for `Int | String` is `Any`,
// so `Array<Int | String>` and `Array<Any>` share a layout — `type(of:)`
// reports `Array<Any>` (the canonical runtime form).
do {
    let ints: [Int] = [1, 2, 3]
    let promoted: [Int | String] = ints
    assert(promoted.count == 3)
    assert(promoted[0] as? Int == 1)
    assert(promoted[2] as? Int == 3)
}

// MARK: 2. Function variance — covariant return
// `() -> Int` is assignable to `() -> (Int | String)` because the return
// position is covariant and `Int` injects into the narrowed `Any`.
do {
    let returnsLeaf: () -> Int = { 42 }
    let returnsNarrowed: () -> (Int | String) = returnsLeaf
    assert(returnsNarrowed() as? Int == 42)
}

// MARK: 3. Marker-protocol propagation — Sendable
// A narrowed `Any` whose every leaf conforms to a marker protocol
// itself satisfies the marker (synthesised). `Int` and `String` are
// both Sendable, so `Int | String` can flow into a `T: Sendable`-
// constrained position without explicit conformance ceremony.
func passSendable<T: Sendable>(_ x: T) -> String {
    if let n = x as? Int    { return "int(\(n))"   }
    if let s = x as? String { return "str(\(s))"   }
    return "?"
}
do {
    let v: Int | String = "hi"
    assert(passSendable(v) == "str(hi)")
}

// MARK: 3b. Marker-protocol propagation — Copyable, BitwiseCopyable
// Three propagation classes:
//   * Copyable — both leaves are Copyable (default), narrowed-Any
//     conforms.
//   * BitwiseCopyable — only when *every* leaf is BC. Int + Bool
//     are BC; String is not (heap buffer). So `Int | Bool` passes,
//     `Int | String` would not (verified offline; positive only
//     here since negative is a compile-error case).
func passCopyable<T: Copyable>(_ x: T) -> Int {
    if x is Int || x is String || x is Bool { return 1 }
    return 0
}
func passBitwiseCopyable<T: BitwiseCopyable>(_ x: T) -> Int {
    if let _ = x as? Int  { return 1 }
    if let _ = x as? Bool { return 2 }
    return 0
}
do {
    let v1: Int | String = "hi"
    assert(passCopyable(v1) == 1, "narrowed-Any with Copyable leaves passes")

    let v2: Int | Bool = 5
    assert(passBitwiseCopyable(v2) == 1, "Int leaf passes BitwiseCopyable")
    let v3: Int | Bool = true
    assert(passBitwiseCopyable(v3) == 2, "Bool leaf passes BitwiseCopyable")
}

// MARK: 4. Typed throws across error domains — the motivating use case
// `throws(NetErr | DecodeErr | AuthErr)` propagates each domain
// unchanged. Catch arms pattern-match each leaf; the do-catch is
// considered exhaustive because every alternative is covered.
struct NetErr:    Error, Equatable { let code: Int }
struct DecodeErr: Error, Equatable { let pos:  Int }
struct AuthErr:   Error, Equatable { let kind: String }

func bootstrap(_ which: Int)
    throws(NetErr | DecodeErr | AuthErr) -> String {
    switch which {
    case 0: throw NetErr(code: 503)
    case 1: throw DecodeErr(pos: 42)
    case 2: throw AuthErr(kind: "expired")
    default: return "ok"
    }
}

do {
    var hits: [String] = []
    for w in 0...3 {
        do {
            let r = try bootstrap(w)
            hits.append("ok:\(r)")
        } catch let e as NetErr    { hits.append("net:\(e.code)") }
          catch let e as DecodeErr { hits.append("dec:\(e.pos)") }
          catch let e as AuthErr   { hits.append("auth:\(e.kind)") }
    }
    assert(hits == ["net:503", "dec:42", "auth:expired", "ok:ok"],
           "got \(hits)")
}

// MARK: 5. Spelling difference: `A | B` vs `B | A`
// Both are legal types over the same leaf set. The existing decision
// stands — spelling is identity. Two values with different spellings
// are runtime-compatible only via explicit `as`.
do {
    let ab: Int | String = 7
    let ba: String | Int = 7
    // The leaves match by dynamic type, so each `as?` extraction works.
    assert(ab as? Int == 7)
    assert(ba as? Int == 7)
    // Type identities differ at compile time — this is a parse-level /
    // metadata-level guarantee Phase 2b.D made observable.
}

// MARK: 6. Cross-shape narrowed → narrowed via explicit `as`
// Per `proposal §Cross-shape conversion`: narrowed → narrowed is
// always explicit, even when the leaf set widens or merely reorders.
do {
    // Widening: `Int | String` → `Int | String | Bool`. Every leaf of
    // the source is also a leaf of the destination, so `as` succeeds.
    let v1: Int | String = 42
    let widened: Int | String | Bool = v1 as (Int | String | Bool)
    assert(widened as? Int == 42)

    // Reordering: `Int | String` → `String | Int`. Same leaves,
    // different spelling — `as` succeeds because every source leaf
    // is structurally a leaf of the destination.
    let reordered: String | Int = v1 as (String | Int)
    assert(reordered as? Int == 42)

    // (Disjoint cross-shape — e.g. `Int | String → Int | Bool` —
    // is rejected at compile time because String isn't a leaf of
    // the destination. Verified by hand; not run from here since
    // test.sh runs files for success.)
}

// MARK: 12m. Issue 8 — tuple alternation vs tuple of narrowed-Any
// Per proposal §Issue 8 these are *distinct* types and don't normalize
// into each other. Both work today; the only quirk is that for tuple-
// alternation alternatives that share the same arity but differ only
// by element types, the constraint solver doesn't backtrack from the
// first alternative when given a literal — explicit `as TupleType`
// is required.
do {
    // Tuple of narrowed-Any: every slot independent
    let a: (Int | String, Int | String) = (1, "two")
    assert(a.0 as? Int == 1)
    assert(a.1 as? String == "two")

    // Two tuple shapes alternation: distinct dynamic shapes
    let b: (Int, String) | (String, Int) = (42, "hi")
    if let v = b as? (Int, String) {
        assert(v == (42, "hi"))
    } else { fatalError() }

    // The other alternative — explicit `as` workaround needed when
    // assigning a literal because the constraint solver doesn't try
    // the second alternative on tuple-literal type inference.
    let c: (Int, String) | (String, Int) = ("hi", 42) as (String, Int)
    if let v = c as? (String, Int) {
        assert(v == ("hi", 42))
    } else { fatalError() }
}

// MARK: 12n. Phase 3.E — function-type throws covariant widen
// `() throws(NetErr) -> Int` is now a subtype of
// `() throws(NetErr | DecodeErr) -> Int`. Sema accepted this via the
// existing leaf-membership rule in matchExistentialTypes; SILGen now
// emits the reabstraction thunk that erases the inner thrown value
// into the outer narrowed-Any error slot. Rationale lives in
// `proposal §Cross-shape` and the typed-throws section.
do {
    struct WidenNetErr: Error { let code: Int }
    struct WidenDecodeErr: Error { let code: Int }

    func throwsNet() throws(WidenNetErr) -> Int {
        throw WidenNetErr(code: 503)
    }

    // Coerce single-source throwing function into a narrowed-Any-throwing
    // function variable. Reabstraction thunk built by SILGen widens the
    // thrown error on rethrow.
    let widened: () throws(WidenNetErr | WidenDecodeErr) -> Int = throwsNet
    var caught = ""
    do {
        _ = try widened()
        fatalError("should have thrown")
    } catch let e as WidenNetErr {
        caught = "net:\(e.code)"
    } catch let e as WidenDecodeErr {
        caught = "dec:\(e.code)"
    }
    assert(caught == "net:503")

    // Happy path through the same thunk.
    func returnsOnly(_ x: Int) throws(WidenNetErr) -> Int { x * 2 }
    let widened2: (Int) throws(WidenNetErr | WidenDecodeErr) -> Int = returnsOnly
    let r = try widened2(21)
    assert(r == 42)

    // Chained widen: narrowed → wider narrowed is *not* an implicit
    // subtype — per proposal §Cross-shape every narrowed → narrowed
    // conversion needs an explicit `as` to preserve spelling-as-
    // identity. So a `() throws(A | B)` value cannot be assigned
    // straight into a `() throws(A | B | C)` slot. The negative
    // probe directly: the assignment below is rejected at compile
    // time. Test as comment + direct rejection probe in test.sh
    // would be ideal; for now leave it as a documented limitation.
}

// MARK: 12p. Unqualified leading-dot member lookup against narrowed-
// Any contextual type. `performMemberLookup` recurses through each
// declared alternative when the receiver is a narrowed-Any base,
// so any leading-dot form (enum cases, static lets, static
// factories, .init shorthand) resolves to whichever leaf owns the
// member. Covers value position, function arg, array literal, and
// return position. `.init` shorthand also works — the
// "cannot construct an existential" fix in `validateInitializerRef`
// is suppressed when the existential is narrowed-Any (the per-leaf
// lookup has already filtered viable inits to leaves that own them).
do {
    enum LE { case x(Int); case y }
    struct WrapLE {
        let v: Int
        init(_ v: Int) { self.v = v }
        init() { self.v = 0 }
        static let zero = WrapLE()
        static func make(_ x: Int) -> WrapLE { WrapLE(x) }
    }

    // Value position
    let v: LE | String = .x(7)           // case + payload
    let w: LE | String = .y               // case, no payload
    let s: LE | String = "hello"         // implicit String injection (literal)
    if let e = v as? LE, case .x(let n) = e {
        assert(n == 7)
    } else { fatalError() }
    if let e = w as? LE, case .y = e {} else { fatalError() }
    assert((s as? String) == "hello")

    // Static let / static factory on a struct alternative
    let z: WrapLE | String = .zero
    let m: WrapLE | String = .make(42)
    assert((z as? WrapLE)?.v == 0)
    assert((m as? WrapLE)?.v == 42)

    // .init shorthand on a struct alternative — picks the leaf whose
    // init signature matches. `.init(Int)` is unambiguous (String has
    // no `init(Int)`); `.init()` would be ambiguous between WrapLE
    // and String, which is correctly diagnosed as ambiguous use of
    // `init()`.
    let i1: WrapLE | String = .init(99)
    assert((i1 as? WrapLE)?.v == 99)

    // Function arg position
    func consume(_ v: LE | String) -> String {
        if let e = v as? LE, case .x(let n) = e { return "x\(n)" }
        if let e = v as? LE, case .y = e { return "y" }
        return v as? String ?? "?"
    }
    assert(consume(.x(11)) == "x11")
    assert(consume(.y) == "y")
    assert(consume("hi") == "hi")

    // Array literal position
    let arr: [LE | String] = [.x(1), .y, "two", .x(3)]
    assert(arr.count == 4)

    // Return position
    func make() -> LE | String { .x(99) }
    assert(consume(make()) == "x99")
}

// MARK: 12o. Runtime cast operators against `any P`
// `is`, `as?`, `as!` against a constrained existential all work for a
// narrowed-Any value: the runtime opens the existential, looks up the
// leaf's own conformance to P, and routes accordingly. Implicit
// conversion (no operator) is *not* allowed — that matches `Any`'s
// behaviour and the proposal's explicit-cast rule for non-marker /
// non-self-conforming protocols. The synthesis maturity §note
// describes why route-1 witness emission is still a Phase 3 ABI item.
do {
    let int: Int | String = 42
    let str: Int | String = "hello"

    // is — checks dynamic conformance through the leaf
    assert(int is any CustomStringConvertible)
    assert(str is any CustomStringConvertible)
    assert(int is any Numeric)        // Int conforms
    assert(!(str is any Numeric))     // String does not
    assert(str is any Sequence)       // String conforms
    assert(!(int is any Sequence))    // Int does not

    // as? — runtime dispatch to leaf's witness
    if let n = int as? any Numeric {
        assert("\(n)" == "42")
    } else { fatalError() }
    assert((str as? any Numeric) == nil)

    // as! — forced version (panics if leaf doesn't conform; here it
    // always conforms because every leaf does, so this is a safe
    // workaround for the missing implicit erasure)
    let desc: any CustomStringConvertible = int as! any CustomStringConvertible
    assert("\(desc)" == "42")
}

// MARK: 12k. Combined `where T: A | B, T: P` constraints
// Both clauses must hold. The same-type desugar of the narrowed-Any
// clause + Phase 3.A's synth conformance for marker / self-conf
// protocols compose: when every leaf conforms to P, the constraint
// is satisfiable; otherwise Sema reports a clear conflict.
struct CombE1: Error {}
struct CombE2: Error {}
func combinedHandle<T>(_ x: T) -> String where T: CombE1 | CombE2, T: Error {
    return String(describing: x)
}
do {
    assert(combinedHandle(CombE1()).contains("CombE1"))
    assert(combinedHandle(CombE2()).contains("CombE2"))
}

// MARK: 12l. Generic wrapper of typed throws — `T: Error` accepts narrowed-Any
// `wrap<T>(_ work: () throws(T) -> Int) where T: Error` is the
// natural library API shape. A caller passing a closure that throws
// `E1 | E2` works because narrowed-Any conforms to Error via the
// synth path, and the generic substitutes T = `any E1 | E2`.
func wrapErrorThrowing<T>(_ work: () throws(T) -> Int) -> Int? where T: Error {
    return try? work()
}
struct WrapErr1: Error { let code: Int }
struct WrapErr2: Error { let pos: Int }
func wrappedRunner(_ k: Int) throws(WrapErr1 | WrapErr2) -> Int {
    if k < 0 { throw WrapErr1(code: k) }
    if k > 10 { throw WrapErr2(pos: k) }
    return k
}
do {
    assert(wrapErrorThrowing { try wrappedRunner(5) } == 5)
    assert(wrapErrorThrowing { try wrappedRunner(-1) } == nil)
    assert(wrapErrorThrowing { try wrappedRunner(99) } == nil)
}

// MARK: 12j. Computed property with typed throws + narrowed-Any return
struct PropContainer {
    var items: [Int]
    var firstOrError: Int | String {
        get throws(TryErr1 | TryErr2) {
            if items.isEmpty { throw TryErr1() }
            return items.first!
        }
    }
}
do {
    let c = PropContainer(items: [42])
    let r = (try? c.firstOrError).flatMap { $0 as? Int }
    assert(r == 42)
    let empty = PropContainer(items: [])
    assert((try? empty.firstOrError) == nil)
}

// MARK: 12i. Tuple types, generic instantiation, protocol associated
// types — narrowed-Any flows through every standard composition shape.
do {
    typealias Pair = (Int | String, Bool)
    let p: Pair = (42, true)
    assert(p.0 as? Int == 42)
    assert(p.1 == true)

    struct GenBox<T> { let v: T }
    let gb: GenBox<Int | String> = GenBox(v: 42)
    assert(gb.v as? Int == 42)

    protocol AssocProducer {
        associatedtype Output where Output == Int | String
        func produce() -> Output
    }
    struct AssocWitness: AssocProducer {
        typealias Output = Int | String
        func produce() -> Int | String { 42 }
    }
    assert(AssocWitness().produce() as? Int == 42)
}

// MARK: 12f. Properties / inout / lazy carrying narrowed-Any
do {
    struct Box { var value: Int | String = 0 }
    var b = Box()
    assert(b.value as? Int == 0)
    b.value = "hi"
    assert(b.value as? String == "hi")

    func mutateInPlace(_ x: inout (Int | String)) { x = 42 }
    var v: Int | String = "before"
    mutateInPlace(&v)
    assert(v as? Int == 42)

    final class Container { lazy var data: Int | String = "lazy" }
    let c = Container()
    assert(c.data as? String == "lazy")
}

// MARK: 12g. Subscripts + protocol associated types carrying narrowed-Any
do {
    struct Bag {
        let items: [Int | String]
        subscript(i: Int) -> Int | String { items[i] }
    }
    let bag = Bag(items: [1, "two", 3])
    assert(bag[0] as? Int == 1)
    assert(bag[1] as? String == "two")

    protocol Producer {
        associatedtype Output
        func make() -> Output
    }
    struct Witness: Producer {
        func make() -> Int | String { "produced" }
    }
    assert(Witness().make() as? String == "produced")
}

// MARK: 12h. Enum case carrying narrowed-Any — direct
// Used to require a typealias workaround because the parameter-list
// parser's lookahead (`canParseTypeSimpleOrComposition`) only handled
// `&`, not `|`. Now that the can-parse loop accepts `|` too, the
// direct spelling works.
do {
    enum Wrapped { case wrap(Int | String), nothing }
    let w: Wrapped = .wrap("hello")
    if case .wrap(let v) = w {
        assert(v as? String == "hello")
    } else {
        fatalError("pattern didn't bind")
    }

    let i: Wrapped = .wrap(42)
    if case .wrap(let v) = i {
        assert(v as? Int == 42)
    }
}

// MARK: 12d. Result<NarrowedAny, Error> — generic carrying narrowed-Any
struct ResultProvideErr: Error {}
func resultProvide(_ k: Int) -> Result<Int | String, ResultProvideErr> {
    if k < 0 { return .failure(ResultProvideErr()) }
    if k == 0 { return .success(42) }
    return .success("hello")
}
do {
    var got: [String] = []
    for k in -1...1 {
        switch resultProvide(k) {
        case .success(let v):
            if let i = v as? Int { got.append("i\(i)") }
            else if let s = v as? String { got.append("s\(s)") }
        case .failure:
            got.append("err")
        }
    }
    assert(got == ["err", "i42", "shello"], "got \(got)")
}

// MARK: 12e. Closure literal carrying narrowed-Any throws
do {
    let f: (Int) throws(TryErr1 | TryErr2) -> String = { k in
        if k < 0 { throw TryErr1() }
        if k > 10 { throw TryErr2() }
        return "got \(k)"
    }
    assert((try? f(5)) == "got 5")
    assert((try? f(-1)) == nil)
    assert((try? f(99)) == nil)
}

// MARK: 12c. `try?` / `try!` + function-typed throws
// Multi-source typed throws integrates with every `try` form and
// works as a first-class function type.
struct TryErr1: Error {}
struct TryErr2: Error {}

func boundedReturn(_ k: Int) throws(TryErr1 | TryErr2) -> Int {
    if k < 0 { throw TryErr1() }
    if k > 10 { throw TryErr2() }
    return k
}

do {
    // try? — Optional(value) on success, nil on any thrown leaf
    assert((try? boundedReturn(5)) == 5)
    assert((try? boundedReturn(-1)) == nil)
    assert((try? boundedReturn(99)) == nil)
    // try! — force, ok when no throw
    assert((try! boundedReturn(7)) == 7)
}

// Function-typed value carrying narrowed throws — pass and re-invoke
do {
    let provider: (Int) throws(TryErr1 | TryErr2) -> Int = boundedReturn
    assert((try? provider(3)) == 3)
    assert((try? provider(-1)) == nil)
}

// MARK: 12b. Full composition: generic constraint + typed throws +
// switch — the proposal's motivating shape, end-to-end.
struct RunnerErr1: Error, Equatable { let v: Int }
struct RunnerErr2: Error, Equatable { let v: Int }
func runner<T>(_ x: T) throws(RunnerErr1 | RunnerErr2) -> Int
    where T: Int | String {
    switch x {
    case let n as Int:
        if n < 0 { throw RunnerErr1(v: n) }
        return n
    case let s as String:
        if s.isEmpty { throw RunnerErr2(v: 0) }
        return s.count
    }
}
do {
    var hits: [String] = []
    func attempt<T>(_ v: T) where T: Int | String {
        do { hits.append("ok:\(try runner(v))") }
        catch let e as RunnerErr1 { hits.append("e1:\(e.v)") }
        catch let e as RunnerErr2 { hits.append("e2:\(e.v)") }
    }
    attempt(5)        // ok 5
    attempt("hello")  // ok 5
    attempt(-3)       // e1 -3
    attempt("")       // e2 0
    assert(hits == ["ok:5", "ok:5", "e1:-3", "e2:0"], "got \(hits)")
}

// MARK: 12a. Switch in the body of `where T: A | B`
// The Phase 2b.E SpaceEngine work + Phase 3.C constraint lowering
// compose: a `switch x` in a body where `T: A | B` (bound to the
// union) is exhaustive over the leaf set with no `default:`. The
// closed conformer set carries through generic bodies.
func dispatch<T>(_ x: T) -> String where T: Int | String {
    switch x {
    case let n as Int:    return "i\(n)"
    case let s as String: return "s\(s)"
    }
}
do {
    assert(dispatch(42) == "i42")
    assert(dispatch("hi") == "shi")
    let v: Int | String = 7
    assert(dispatch(v) == "i7")
}

// MARK: 12. `where T: A | B` — generic constraint
// Phase 3.C: prototype desugars `where T: A | B` to `where T == A | B`
// because Swift's generic system doesn't model disjunctive
// requirements. Callers passing leaves get the call-site leaf-
// injection rule. The body sees T as the union itself.
//
// (The compiler emits a "same-type makes T non-generic" warning,
// inherited from the `T == ...` desugaring. Acceptable for prototype;
// real set-membership lands when disjunctive requirements are
// designed.)
func acceptUnion<T>(_ x: T) -> String where T: Int | String {
    if let i = x as? Int    { return "i\(i)" }
    if let s = x as? String { return "s\(s)" }
    return "?"
}
do {
    assert(acceptUnion(42) == "i42")
    assert(acceptUnion("hi") == "shi")
    let v: Int | String = 7
    assert(acceptUnion(v) == "i7")
    // Reverse-spelling alternation requires an explicit `as` reshape
    // at the call site. The cast itself is a free SIL relabel — both
    // sides erase to the same Any-singleton existential layout — so
    // the runtime dispatch through `acceptUnion`'s body picks up the
    // dynamic leaf (String "hi") regardless of the reshape.
    let v2: String | Int = "hi"
    assert(acceptUnion(v2 as Int | String) == "shi")
}

// MARK: 8a. `as!` to constrained existential works (today's workaround
// for non-marker / non-self-conforming protocol use). The runtime
// dynamic-cast machinery opens the narrowed-Any, looks up the leaf's
// own conformance to the target protocol, and rewraps. This is what
// makes `try encoder.encode(v as! any Encodable)` work in user code
// before route-1 synthesis lands. See `proposal §Synthesis maturity`.
do {
    let v: Int | String = 42
    let e: any Encodable = v as! any Encodable
    let data = try JSONEncoder().encode(e)
    let s = String(data: data, encoding: .utf8) ?? ""
    assert(s == "42")

    let v2: Int | String = "hi"
    let e2: any Encodable = v2 as! any Encodable
    let s2 = String(data: try JSONEncoder().encode(e2), encoding: .utf8) ?? ""
    assert(s2 == "\"hi\"")
}

// MARK: 9. Reflection — `Mirror(reflecting:)` sees the dynamic leaf
// Per proposal §Future directions §Reflection, `Mirror` should expose
// the closed-class membership. Today, the existing existential-mirror
// behaviour already gives the dynamic leaf — sufficient for typical
// debugging / printing use.
do {
    let v: Int | String = 42
    let m = Mirror(reflecting: v)
    assert("\(m.subjectType)" == "Int")
}

// MARK: 10. Containers + closures + tuples carrying narrowed-Any
do {
    let arr: [Int | String] = [1, "two", 3]
    assert(arr.count == 3)

    let dict: [String: Int | Bool] = ["a": 1, "b": true]
    assert(dict.count == 2)

    let tup: (Int | String, Bool) = (42, true)
    assert(tup.0 as? Int == 42)
    assert(tup.1 == true)

    let opt: (Int | String)? = 42
    if let v = opt { assert(v as? Int == 42) } else { fatalError() }

    let f: (Int | String) -> String = { v in
        if let i = v as? Int { return "i\(i)" }
        if let s = v as? String { return "s\(s)" }
        return "?"
    }
    assert(f(7) == "i7")
    assert(f("zz") == "szz")
}

// MARK: 11. Generic functions taking / returning narrowed-Any
func wrapNarrowed<T>(_ x: T) -> Int | String where T == Int | String { x }
func firstOf<T>(_ xs: [T]) -> T? where T == Int | String { xs.first }

do {
    assert(wrapNarrowed(42 as (Int | String)) as? Int == 42)
    assert(wrapNarrowed("hi" as (Int | String)) as? String == "hi")

    let xs: [Int | String] = ["a", 1, "b"]
    if let f = firstOf(xs) { assert(f as? String == "a") }
    else { fatalError() }
}

// MARK: 8. `where T == A | B` — generic same-type constraint
// Per proposal §Generics: `where T == A | B` means T is exactly the
// narrowed-Any type. The body sees the existential value; callers can
// pass either a leaf (via leaf injection at call site) or the
// narrowed-Any directly.
func describeUnion<T>(_ x: T) -> String where T == Int | String {
    return "got(\(x))"
}
do {
    let v: Int | String = 42
    assert(describeUnion(v) == "got(42)")
    assert(describeUnion(7) == "got(7)")        // Int leaf injection
    assert(describeUnion("hi") == "got(hi)")    // String leaf injection
}

// MARK: 7a. as? / as! / is for narrowed `Any`
do {
    let v: Int | String = 42
    // is — runtime leaf identity
    assert(v is Int)
    assert(!(v is String))
    // as? — Optional, succeeds when leaf matches
    assert(v as? Int == 42)
    assert(v as? String == nil)
    // as! — force, succeeds for matching leaf
    let i: Int = v as! Int
    assert(i == 42)
    // Cross-shape as? — every alt of source is a leaf of dest
    let reordered: (String | Int)? = v as? (String | Int)
    if let r = reordered { assert(r as? Int == 42) }
}

// MARK: 7. Overload resolution rules
// `proposal §Overload resolution`:
//   1. Exact-shape overload wins.
//   2. Cross-shape (different spelling) is *not* considered;
//      explicit `as` required.
//   3. Separate `A` + `B` overloads → ambiguous, rejected.
//   4. Otherwise resolves to a supertype overload (Any).
//
// Rule 1 + 4 covered by §3 (overload2.swift offline). Rule 2 + 3 are
// the negative cases — they reject at compile time and don't fit
// test.sh's run-for-success harness. They're verified by hand.
func handleNarrowedExact(_ x: Int | String) -> String { "exact" }
func handleAny(_ x: Any) -> String { "any" }
do {
    let v: Int | String = 42
    // Rule 1: exact-shape wins over Any.
    assert(handleNarrowedExact(v) == "exact")
    // Rule 4: when only Any is available, fallback applies.
    assert(handleAny(3.14) == "any")
}
// `throws(A | B)` in a protocol requirement requires witnesses to use
// the *exact* spelling. `throws(B | A)` is rejected as a non-witness
// (cf. proposal §Cross-shape — "spelling is identity"). The negative
// case is verified by hand-building both witnesses and confirming the
// reversed-spelling one fails to compile; here we only run the
// positive case as a runtime assertion.
struct ServiceErrA: Error { let code: Int }
struct ServiceErrB: Error { let kind: String }

protocol ThrowsService {
    func work() throws(ServiceErrA | ServiceErrB) -> Int
}

struct ExactWitness: ThrowsService {
    func work() throws(ServiceErrA | ServiceErrB) -> Int { 99 }
}

do {
    let s: any ThrowsService = ExactWitness()
    let r = try s.work()
    assert(r == 99)
}

// MARK: 12q. inout / class property / autoclosure / variadic
// compositions with narrowed-Any. These all "should just work"
// because narrowed-Any is layout-compatible with Any and Sema
// treats it as an existential everywhere it matters.
do {
    // inout
    func bumpInt(_ x: inout Int | String) {
        if let n = x as? Int { x = n + 1 }
    }
    var v: Int | String = 41
    bumpInt(&v)
    assert((v as? Int) == 42)

    // Class property of narrowed-Any (reference-typed mutable storage)
    class Holder {
        var data: Int | String = 0
        func update(_ x: Int | String) { data = x }
    }
    let h = Holder()
    h.update("hello")
    assert((h.data as? String) == "hello")
    h.update(7)
    assert((h.data as? Int) == 7)

    // Autoclosure delivering narrowed-Any
    func lazyValue(_ x: @autoclosure () -> Int | String) -> Int | String { x() }
    let r = lazyValue(99)
    assert((r as? Int) == 99)

    // Variadic narrowed-Any
    func describe(_ items: (Int | String)...) -> String {
        items.map { ($0 as? Int).map { "i\($0)" } ?? ($0 as? String).map { "s\($0)" } ?? "?" }
            .joined(separator: ",")
    }
    assert(describe(1, "a", 2) == "i1,sa,i2")
}

// MARK: 12q. Cross-spelling try-propagation (forum issue raised by @ksluder)
// Two libraries each declaring the same leaf set in different spellings
// should compose at a `try` site without an explicit cast. Spelling-as-
// identity bites at the function-type-signature boundary (function-value
// assignment, witness conformance); try-propagation is per-leaf — each
// possible thrown leaf must fit the outer's declared set, regardless of
// how the inner side spelled the alternation.
//
// Forum: https://forums.swift.org/t/pitch-narrowed-any/86369/5
// Rule:  proposal §"Generics: where T: A | B" →
//        "Try-propagation is per-leaf, not per-spelling"
do {
    struct NetErrK: Error { let code: Int }
    struct FsErrK: Error { let path: String }

    // "Library A" picks NetErr | FsErr ordering.
    func libA(throwingNet: Bool) throws(NetErrK | FsErrK) -> Int {
        if throwingNet { throw NetErrK(code: 500) }
        return 1
    }

    // "Library B" picks the opposite ordering — a different *type* under
    // spelling-as-identity, same leaf set.
    func libB(throwingFs: Bool) throws(FsErrK | NetErrK) -> Int {
        if throwingFs { throw FsErrK(path: "/etc") }
        return 2
    }

    // Consumer composes both with whichever spelling — try-propagation
    // is per-leaf, no cast needed.
    func compose() throws(NetErrK | FsErrK) -> Int {
        let a = try libA(throwingNet: false)
        let b = try libB(throwingFs: false)   // ← cross-spelling propagation
        return a + b
    }

    let happy = try compose()
    assert(happy == 3)

    // libA throwing NetErr — same-spelling propagation through outer.
    func runA() throws(NetErrK | FsErrK) -> Int {
        return try libA(throwingNet: true)
    }
    var got = ""
    do { _ = try runA() }
    catch let e as NetErrK { got = "net:\(e.code)" }
    catch let e as FsErrK  { got = "fs:\(e.path)" }
    assert(got == "net:500")

    // libB throwing FsErr — cross-spelling propagation:
    // inner spelled `FsErr | NetErr`, outer spelled `NetErr | FsErr`,
    // dynamic value is FsErr → fits outer's set.
    func runB() throws(NetErrK | FsErrK) -> Int {
        return try libB(throwingFs: true)
    }
    got = ""
    do { _ = try runB() }
    catch let e as NetErrK { got = "net:\(e.code)" }
    catch let e as FsErrK  { got = "fs:\(e.path)" }
    assert(got == "fs:/etc")
}

// MARK: 12r. Uninhabited (Never) leaves and the inhabited-subset rule
// Forum reference: https://forums.swift.org/t/pitch-narrowed-any/86369/9
// (mattie's enum-desugar question + Nobody1707's `A | Never` follow-up).
//
// `Never` is uninhabited — no value of type Never can be constructed.
// When `Never` appears as a leaf, call-site reachability checks
// ("does this throw?", "is this case reachable?", "does this cast
// have any chance of succeeding?") are decided against the
// *inhabited* subset of the leaf set, not the static leaf set:
//
//   throws(A | Never)     → inhabited {A}; `try` required, same as throws(A)
//   throws(Never | A)     → same inhabited set after stripping Never; same behaviour
//   throws(Never | Never) → inhabited set empty; non-throwing per SE-0413 extension
//   switch on `A | Never` → no `case _ as Never:` arm required for exhaustiveness
//
// Type identity is preserved: A | Never and A still have different
// mangled names / signatures / witness-table identities. The
// inhabited-subset rule only governs call-site reachability decisions,
// not type identity itself.
do {
    struct NeverE: Error { let msg: String }

    // (1) throws(A | Never) — A is reachable, Never never is.
    func mustTry() throws(NeverE | Never) -> Int {
        throw NeverE(msg: "boom")
    }
    var got = ""
    do { _ = try mustTry() } catch let e as NeverE { got = e.msg }
    assert(got == "boom")

    // (2) throws(Never | A) — same inhabited subset, different spelling.
    func mustTrySwapped() throws(Never | NeverE) -> Int {
        throw NeverE(msg: "boom2")
    }
    got = ""
    do { _ = try mustTrySwapped() } catch let e as NeverE { got = e.msg }
    assert(got == "boom2")

    // (3) Cross-spelling try-propagation across A|Never and Never|A:
    //     same inhabited subset {NeverE}, propagation is per-leaf
    //     (and Never is trivially in any outer set).
    func compose() throws(NeverE | Never) -> Int {
        return try mustTrySwapped()   // inner: throws(Never|NeverE), outer: throws(NeverE|Never)
    }
    got = ""
    do { _ = try compose() } catch let e as NeverE { got = e.msg }
    assert(got == "boom2")

    // (4) Switch on `A | Never` value — `case _ as Never` arm is NOT
    //     required for exhaustiveness (Never leaf is unreachable).
    let v: Int | Never = 42
    switch v {
    case let n as Int: assert(n == 42)
    // no `case _ as Never:` arm — must not produce a "missing case" diagnostic.
    }

    // (5) Leaf injection of A into A | Never works (A is a leaf,
    //     dynamic type is A; Never branch is unreachable).
    let w: String | Never = "hi"
    assert((w as? String) == "hi")
    assert((w as? Never) == nil)   // Never cast always nil — unreachable leaf
}

// MARK: 12s. `throws(Never | Never)` → non-throwing per SE-0413 extension
// Forum reference: https://forums.swift.org/t/pitch-narrowed-any/86369/12
// SE-0413 already special-cases `throws(Never)` as non-throwing. The
// natural multi-leaf extension is "if the inhabited subset of the
// throws set is empty, the function is non-throwing at the call
// site, no `try` required". Mechanical rule: strip Never leaves,
// then apply the existing throws-set-empty check.
//
// Type identity is preserved: `Never | Never` and `Never` still have
// distinct mangled names / signatures / witness-table identities.
// The rule lives in TypeCheckEffects' call-site classifier
// (`isNeverThrownError`), not in canonicalisation.
do {
    func nothrows() throws(Never | Never) -> Int { 99 }
    let n = nothrows()              // ← no `try` required
    assert(n == 99)

    // Verify the same call inside a non-throwing function compiles —
    // the call site is genuinely non-throwing, not just "try-able".
    func wrap() -> Int { return nothrows() }
    assert(wrap() == 99)
}
