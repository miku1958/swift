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

// §8. Cross-spelling extension dispatch — per-spelling rule.
extension Array where Element == String | Int { // expected-note {{where}}
    func extProbe() -> Int { return self.count }
}
do {
    let zs: [Int | String] = [1, "a"]
    _ = zs.extProbe()       // expected-error {{requires the types}}
}

// §9. `extension Int | String { }` — narrowed-Any is not nominal.
extension Int | String {    // expected-error {{non-nominal type 'Int | String' cannot be extended}}
                            // expected-note@-1 {{narrowed-Any types are existentials with a closed leaf set}}
    func leafProbe() -> Int { return 0 }
}

// §10. Implicit cross-shape conversion — error + fix-it that
// inserts ` as <toType-spelling>` after the source expression
// (proposal §"Diagnostic and fix-it for implicit cross-shape").
// Sema also attaches the legacy ` as! T` fix-it from
// `missing_explicit_conversion`'s general path; both are emitted
// and verify-mode locks both in.
do {
    let a: Int | String = 7
    let _: String | Int = a    // expected-error {{cannot convert value of type 'Int | String' to specified type 'String | Int'}} {{28-28= as! String | Int}} {{28-28= as String | Int}}
}
