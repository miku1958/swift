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

// §12. Multi-clause `where T: A | B, T: C | D` — rejected.
// Decision row #13: a single narrowed-Any constraint per type
// parameter; the type-checker sees the second clause as a
// conflicting same-type requirement (slice-3.C lowers
// `where T: A | B` to `where T == A | B`).
func f12<T>(_ x: T) where T: Int | String, T: Int | Bool {}
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

// §14. Cross-spelling at argument position of a generic call (proposal
// §"Generics: where T: A | B"). `where T: A | B` is desugared to
// `T == A | B` in v1, so passing a value spelled `B | A` triggers the
// SameType requirement check and is rejected. Spelling-as-identity:
// `T = A | B` and `T = B | A` are different bindings (different mangled
// names, different witness identities), so the user must reshape with
// an explicit `as`. The cast itself is a free SIL relabel — both sides
// erase to the same Any-singleton existential layout, no runtime check
// — so the fix-it suggests ` as <expected>`, not ` as!`. Lifting the
// explicit-cast requirement to a fully order-free leaf-set match
// (where `where T: A | B` and `where T: B | A` accept the same set of
// substitutions) is the True set-membership future direction.
func processGeneric<T>(_ x: T) where T: Int | String {}
do {
    let v: String | Int = "hi"
    processGeneric(v)    // expected-error {{argument type 'String | Int' does not conform to expected type 'Int | String'}} {{21-21= as Int | String}}
}
