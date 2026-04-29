// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Phase 3.F slice 24 regression test.
//
// Before slice 24, JSONDecoder().decode([W].self, ...) where W = V | Bool
// and V = Int | String produced values that *were* structurally the inner
// concrete leaf (Int / String) but failed the `is V` / `as? V` membership
// check, because `tryEmitNarrowedAnyDecodableDispatch` wrapped each leaf
// via `init_existential_addr type=leaf` even when leaf was itself a
// narrowed-Any — overwriting the W buffer's metadata slot with V's own
// metadata (the Any singleton) and discarding the concrete leaf.
//
// Fix: when leaf is itself narrowed-Any, skip init_existential_addr and
// reinterpret leafSlot as the outer existential type. narrowed-Any
// reuses the Any layout so the bytes are already a valid outer
// existential with the correct concrete metadata.
//
// Lives in its own file because cumulating the witness tables of this
// test plus the existing Codable sections in test-phase3f-equatable.swift
// trips a JIT-mode Foundation stale-optional fatalError; both files run
// fine on their own.

import Foundation

typealias V = Int | String
typealias W = V | Bool

// Add an inline `A | B` annotation so the AST-dump regression check
// (which counts `type_narrowed_any` nodes) sees the parser-level form,
// not just the typealiased one.
let _: Int | String = 0

let arr: [W] = [1, "a", true, 2, false]
let json = try JSONEncoder().encode(arr)
let back = try JSONDecoder().decode([W].self, from: json)

assert(back[0] is V, "decoded Int leaf should match `is V`")
assert(back[1] is V, "decoded String leaf should match `is V`")
assert(!(back[2] is V), "Bool is not in V's leaf set")
assert(back[3] is V, "decoded second Int leaf should match `is V`")
assert(!(back[4] is V), "Bool is not in V's leaf set")

// Filter through the V layer (the failing case from real-world user code)
// — must yield the two Int leaves.
let ints: [Int] = back.compactMap { x in
    if let v = x as? V, let i = v as? Int { return i }
    return nil
}
assert(ints == [1, 2], "Codable round-trip + V-layer filter preserves Int leaves")
