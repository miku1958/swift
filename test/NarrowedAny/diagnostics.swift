// RUN: %target-typecheck-verify-swift

// Verify-mode tests for narrowed-`Any` Sema diagnostics. Locks in
// the negative paths the runtime test bed can't exercise (because
// hard errors stop compilation). Each annotation is a contract — if
// Sema's wording or the rule itself drifts, this file fails
// immediately. Substrings are matched, so wording around the core
// claim can change without breaking the test.
//
// Coverage:
//   §1  disjoint cast `as` / `as?` / `as!` — hard error per row #18
//   §2  disjoint `is` — warning (Swift convention)
//   §3  partial-overlap `as` — error: requires totality
//   §4  cross-spelling subset `as?` / `as!` — slice-18 widening warn
//   §5  partial-overlap `as?` — silent (runtime decides)
//   §6  Direction B disjoint — error
//   §7  pattern `case _ as T` — disjoint pattern arm errors
//   §8  cross-spelling extension dispatch — error
//   §9  `extension Int | String { }` — non-nominal target
//   §17 container narrowing — `[A | B]` → `[A]`, `[K: V | W]` → `[K: V]`
//   §18 disjoint container element sets — `[A | B]` → `[C | D]`
//   §19 function-type variance — strict invariant on narrowed-Any positions

// §1. Disjoint cast in any of as / as? / as!
do {
    let v: Int | String = 42
    _ = v as Bool       // expected-error {{is not convertible to 'Bool'}}
                        // expected-note@-1 {{did you mean to use 'as!' to force downcast?}}
    _ = v as? Bool      // expected-error {{'Bool' is not in the closed leaf set of}}
                        // expected-note@-1 {{valid leaves of}}
    _ = v as! Bool      // expected-error {{'Bool' is not in the closed leaf set of}}
                        // expected-note@-1 {{valid leaves of}}
}

// §2. Disjoint `is` — warning (no upgrade to error)
do {
    let v: Int | String = 42
    _ = v is Bool       // expected-warning {{always evaluates to false because 'Bool' is not in the closed leaf set of}}
                        // expected-note@-1 {{valid leaves of}}
}

// §3. Partial-overlap `as` form — Int shared, but `as` requires
// every source leaf fit. `Double` has no home in `String | Int`.
do {
    let o: Int | Double = 7
    _ = o as String | Int   // expected-error {{cannot convert value of type 'Int | Double' to type 'String | Int' in coercion}}
}

// §4. Cross-spelling subset — slice-18's "always succeeds; use 'as'"
do {
    let v: Int | String = 7
    _ = v as String | Int   // OK — this is the right form for cross-spelling reshape
    _ = v as? String | Int  // expected-warning {{always succeeds because every leaf of 'Int | String' is in the closed leaf set of 'String | Int'; consider using 'as'}}
    _ = v as! String | Int  // expected-warning {{always succeeds because every leaf of 'Int | String' is in the closed leaf set of 'String | Int'; consider using 'as'}}
}

// §5. Partial-overlap `as?` — runtime decides, no diagnostic.
do {
    let o: Int | Double = 7
    _ = o as? String | Int  // OK — partial overlap, `as?` returns nil at runtime if Double
}

// §6. Direction B: concrete non-leaf source → narrowed-`Any`,
// disjoint leaf set.
do {
    typealias V = Int | String
    let b = true
    _ = b as? V             // expected-error {{cast from 'Bool' to 'V' (aka 'Int | String') cannot succeed because 'Bool' is not in the closed leaf set of}}
                            // expected-note@-1 {{valid leaves of}}
}

// §7. Pattern form: `case _ as T` against a non-leaf T —
// disjoint pattern arm is a hard compile error.
do {
    let v: Int | String = "yo"
    switch v {
    case _ as Int: break
    case _ as String: break
    case _ as Bool: break    // expected-error {{'Bool' is not in the closed leaf set of}}
                              // expected-note@-1 {{valid leaves of}}
    }
}

// §8. Cross-spelling and leaf-injection extension dispatch —
// per-spelling rule. v1 ships explicit-cast for both axes
// (proposal §"Containers and extensions"):
//
// - Leaf-injection (§8b below) goes through SameTypeRequirementFailure
//   and gets an auto-fix-it that wraps the receiver in `(receiver as
//   [Element])`. The cast is an O(N) per-element wrap at runtime.
//
// - Cross-spelling (§8a below) currently goes through a different
//   diagnostic path (per-alternative comparison surfacing as "any X"
//   and "any Y" mismatch) which doesn't carry narrowed-`Any` context;
//   the fix-it for that axis is a separate diagnostic-quality
//   improvement, not blocked on v1 review (cross-spelling reshape
//   itself works end-to-end via explicit `as`, runtime-free relabel).
//
// The implicit-lift form for both axes is the deferred follow-up
// (proposal §"Future directions § Per-element leaf injection at the
// extension boundary").
extension Array where Element == String | Int { // expected-note 2 {{where}}
    func extProbe() -> Int { return self.count }
}
do {
    // §8a. Cross-spelling: same leaf set, different spelling.
    // Diagnostic surfaces as per-alternative type mismatch
    // (no fix-it attached today; explicit reshape required).
    let zs: [Int | String] = [1, "a"]
    _ = zs.extProbe()       // expected-error {{requires the types}}

    // §8b. Leaf injection: leaf-typed receiver. Fix-it inserts
    // `(xs as [String | Int])` — O(N) per-element wrap at runtime.
    let xs: [Int] = [1, 2, 3]
    _ = xs.extProbe()       // expected-error {{requires the types}} {{9-9=(}} {{11-11= as [String | Int])}}
}

// §9. `extension Int | String { }` — narrowed-Any is not nominal.
extension Int | String {    // expected-error {{non-nominal type 'Int | String' cannot be extended}}
                            // expected-note@-1 {{narrowed-Any types are existentials with a closed leaf set}}
    func leafProbe() -> Int { return 0 }
}

// §10. Implicit cross-shape conversion — error + fix-it.
// Per the proposal's fix-it table, cross-spelling subset (same leaf
// set, different order) → ` as T2` (free SIL relabel — both sides
// erase to the same Any-singleton layout, so no runtime check is
// needed). Partial overlap (different leaf sets) → ` as? T2` (runtime
// check required). Verify-mode locks the fix-its in. The legacy
// `missing_explicit_conversion` path also fires and contributes its
// own copy of the cross-shape `as` fix-it; lit-verify accepts the
// duplicate as a single match.
do {
    // Subset: every source leaf is in target's set. Different
    // spelling, so it's a cross-shape conversion. Free relabel —
    // fix-it suggests ` as T2`.
    let a: Int | String = 7
    let _: String | Int = a    // expected-error {{cannot convert value of type 'Int | String' to specified type 'String | Int'}} {{28-28= as String | Int}}
}
do {
    // Partial overlap: Int is shared, Double-only-in-source.
    // Runtime check required — fix-it suggests ` as? T2` (the user
    // may need to make the binding Optional). The legacy
    // `missing_explicit_conversion` path attaches ` as! T2` as a
    // secondary suggestion.
    let a: Int | Double = 7
    let _: String | Int = a    // expected-error {{cannot convert value of type 'Int | Double' to specified type 'String | Int'}} {{28-28= as! String | Int}} {{28-28= as? String | Int}}
}

// §11. Issue 9 `&` mixing — narrowed-Any cannot appear on either
// side of `&`. Decision row #13: `(A | B) & P`, `(A | B) & C`, and
// `(A | B) & (C | D)` are all rejected directly (no normalisation,
// per Spelling-as-identity). Falls under Swift's stock
// "non-protocol, non-class type cannot be used within a protocol-
// constrained type" diagnostic; no narrowed-Any-specific wording.
protocol P11 {}
class C11 {}
typealias T11a = (Int | String) & P11        // expected-error {{non-protocol, non-class type 'Int | String' cannot be used within a protocol-constrained type}}
typealias T11b = (Int | String) & C11        // expected-error {{non-protocol, non-class type 'Int | String' cannot be used within a protocol-constrained type}}
typealias T11c = (Int | String) & (Int | String)  // expected-error {{non-protocol, non-class type 'Int | String' cannot be used within a protocol-constrained type}} expected-error {{non-protocol, non-class type 'Int | String' cannot be used within a protocol-constrained type}}

// §12. Multi-clause `where T == A | B, T == C | D` — rejected.
// Decision row #13: a single narrowed-Any constraint per type
// parameter; the type-checker sees the second same-type clause as a
// conflicting requirement. v1 only accepts the `==` form (the colon
// form is rejected at parse time by §16 below).
func f12<T>(_ x: T) where T == Int | String, T == Int | Bool {}
                              // expected-error@-1 {{no type for 'T' can satisfy both}}

// §13. Cross-spelling Array assignment (proposal §"Containers and
// extensions"; row #21 + #33). Implicit cross-spelling container
// conversion is rejected with `cannot assign value of type ...` plus
// a generic-argument-mismatch note pointing at the differing
// `Element` spellings. The user is expected to add an explicit
// reshape `as [String | Int]` (runtime-free relabel — a single
// `unchecked_addr_cast` at SIL level — since both sides erase to the
// same Any-singleton element layout). Used to crash in
// `repairFailures` via a malformed `ExistentialType(<concrete leaf>)`
// before the cross-spelling-aware fix in
// `matchDeepEqualityTypes::NarrowedAnyType` branch (records
// `GenericArgumentsMismatch` for plain conversion, hands off to
// `fixRequirementFailure` when a `where`-clause requirement is on
// the locator).
do {
    let zs: [Int | String] = [1, "a"]
    let _: [String | Int] = zs    // expected-error {{cannot assign value of type '[Int | String]' to type '[String | Int]'}} {{31-31= as [String | Int]}}
                                  // expected-note@-1 {{arguments to generic parameter 'Element' ('Int | String' and 'String | Int') are expected to be equal}}
}

// §14. Cross-spelling at argument position of a generic call.
// v1 commits to `where T == A | B` (the colon form is rejected at
// parse time by §16 below), so passing a value spelled `B | A`
// triggers the SameType requirement check and is rejected.
// Spelling-as-identity: `T = A | B` and `T = B | A` are different
// bindings (different mangled names, different witness identities),
// so the user must reshape with an explicit `as`. The cast itself
// is a free SIL relabel — both sides erase to the same Any-singleton
// existential layout, no runtime check — so the fix-it suggests
// ` as <expected>`, not ` as!`. Lifting the explicit-cast requirement
// to a fully order-free leaf-set match is the True set-membership
// future direction (which would also re-enable the colon form with
// proper set-membership semantics).
func processGeneric<T>(_ x: T) where T == Int | String {}
do {
    let v: String | Int = "hi"
    processGeneric(v)    // expected-error {{argument type 'String | Int' does not conform to expected type 'Int | String'}} {{21-21= as Int | String}}
}

// §16. Colon form `where T: A | B` is rejected at parse time —
// reserved for the True set-membership future direction. Both the
// where-clause form and the generic-parameter shorthand error.
func f16a<T>(_ x: T) where T: Int | String {}    // expected-error {{narrowed-`Any` (`A | B`) cannot appear in a conformance constraint; v1 commits to the same-type form, write 'where T == A | B' instead (the colon form is reserved for a future direction)}}

func f16b<T: Int | String>(_ x: T) {}            // expected-error {{narrowed-`Any` (`A | B`) cannot appear in a conformance constraint; v1 commits to the same-type form, write 'where T == A | B' instead (the colon form is reserved for a future direction)}}

// §15. Return position with disjoint leaf sets — must still error.
// Cross-spelling and leaf-injection at return position propagate
// silently (proposal §"Return-position is per-leaf, not per-spelling";
// runtime returned value is one concrete leaf, fits any compatible
// outer set). But disjoint sets — no inhabited leaf can fit — must
// reject; the positive cases live in the runtime test bed. The
// fix-it points at `as!` because the runtime check is genuinely
// non-trivial here (Int|String → Bool|Double can never succeed).
func returnIntString() -> Int | String { return 7 }
func disjointReturn() -> Bool | Double {
    return returnIntString()  // expected-error {{cannot convert return expression of type 'Int | String' to return type 'Bool | Double'}} {{29-29= as! Bool | Double}}
}

// §17. Container narrowing — generic containers are invariant in
// their element type (proposal §"Subtyping lattice"; row #21). Going
// from a wider leaf set to a narrower one cannot lift element-wise
// because some inhabitants don't fit, so it is rejected at Sema with
// the standard generic-argument-mismatch wording. Element-lift in the
// widening direction is *also* rejected — see §20 below for the
// `[Int]` → `[Int | String]` case; the user-facing recovery is an
// explicit `as [Int | String]` (positive runtime bed
// `phase2f_runtime.swift §1`).
do {
    let zs: [Int | String] = [1, "a"]
    let _: [Int] = zs    // expected-error {{cannot assign value of type '[Int | String]' to type '[Int]'}}
                         // expected-note@-1 {{arguments to generic parameter 'Element' ('Int | String' and 'Int') are expected to be equal}}
}
do {
    let m: [String: Int | Bool] = ["a": 1]
    let _: [String: Int] = m    // expected-error {{cannot assign value of type '[String : Int | Bool]' to type '[String : Int]'}}
                                // expected-note@-1 {{arguments to generic parameter 'Value' ('Int | Bool' and 'Int') are expected to be equal}}
}

// §18. Disjoint container element sets — `[A | B]` → `[C | D]` with
// no overlapping leaves cannot succeed for any element, so the
// implicit conversion is rejected. Mirrors §15's return-position rule
// at the container level. Cross-spelling (same leaf set, different
// order) goes through §13's path with a `as` fix-it; truly disjoint
// has no fix-it because no relabel can rescue it.
do {
    let zs: [Int | String] = [1, "a"]
    let _: [Bool | Double] = zs    // expected-error {{cannot assign value of type '[Int | String]' to type '[Bool | Double]'}}
                                   // expected-note@-1 {{arguments to generic parameter 'Element' ('Int | String' and 'Bool | Double') are expected to be equal}}
}

// §19. Function-type variance — narrowed-`Any` positions are strict
// invariant (proposal §"Subtyping lattice"). A leaf-typed parameter
// does not contravary into a narrowed-`Any` parameter (would require
// caller-side widening); the relaxation lives in the variance
// future direction (proposal §"Variance at the protocol-witness
// boundary"). v1 rejects with the standard function-conversion
// wording.
do {
    let f: (Int) -> Void = { _ in }
    let _: (Int | String) -> Void = f    // expected-error {{cannot convert value of type '(Int) -> Void' to specified type '(Int | String) -> Void'}}
}

// §20. Container widening (the leaf-injection direction at direct
// binding) — strict invariance applies symmetrically to §17's
// narrowing direction. A leaf-typed source array cannot implicitly
// promote into a narrowed-`Any` element type, even though every
// element is value-level injectable. The per-element wrap is *not*
// bit-identical (source `Array<Int>` element stride 8 bytes vs.
// destination `Array<Int | String>` element stride 32 bytes for the
// Any-singleton element layout), so the cast carries real SIL work
// and must be explicit. Recovery: ` as [Int | String]`.
//
// Same story for `Set<Int>` → `Set<Int | String>` and for narrowing
// to fully open `Any` (`[Int | String]` → `[Any]`). The latter is a
// free SIL relabel (both sides hold Any-singleton element layout),
// but the implicit conversion is still rejected — the user must
// spell the erasure with ` as [Any]`. Together these are the three
// "container axis" silent passes registered in proposal
// §"Strict-invariant rule has silent passes". Function-type
// parameter narrowing — the fourth — remains silent today and is
// tracked separately in that gap entry.
do {
    let xs: [Int] = [1, 2, 3]
    let _: [Int | String] = xs    // expected-error {{cannot assign value of type '[Int]' to type '[Int | String]'}}
                                  // expected-note@-1 {{arguments to generic parameter 'Element' ('Int' and 'Int | String') are expected to be equal}}
}
do {
    let zs: [Int | String] = [1, "a"]
    let _: [Any] = zs    // expected-error {{cannot assign value of type '[Int | String]' to type '[Any]'}}
                         // expected-note@-1 {{arguments to generic parameter 'Element' ('Int | String' and 'Any') are expected to be equal}}
}
do {
    let s: Set<Int> = [1, 2, 3]
    let _: Set<Int | String> = s    // expected-error {{cannot assign value of type 'Set<Int>' to type 'Set<Int | String>'}}
                                    // expected-note@-1 {{arguments to generic parameter 'Element' ('Int' and 'Int | String') are expected to be equal}}
}
