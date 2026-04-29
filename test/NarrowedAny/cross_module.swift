// Cross-module: a library exposes narrowed-`Any` in its public API
// and a downstream module imports + uses it. Exercises:
//   - `.swiftmodule` binary serialisation of NarrowedAnyType
//   - public typealias / fn return / struct field / Optional<V> /
//     typed throws crossing the module boundary
//
// RUN: %empty-directory(%t)
// RUN: split-file --leading-lines %s %t
//
// RUN: %target-build-swift -emit-module -emit-library -module-name Lib \
// RUN:     -emit-module-path %t/Lib.swiftmodule \
// RUN:     -o %t/%target-library-name(Lib) \
// RUN:     %t/Lib.swift
//
// RUN: %target-build-swift -I %t -L %t -lLib -o %t/driver %t/Driver.swift
// RUN: %target-codesign %t/driver
// RUN: %target-run %t/driver
//
// REQUIRES: executable_test

//--- Lib.swift
// Slice 39 — public narrowed-Any in a serialised module's API.
// The Lib module is built as `-emit-module -emit-library`; the
// driver (Driver.swift in the same directory) imports it and uses
// each exported declaration. Both halves must round-trip the
// `NarrowedAnyType` records through the .swiftmodule binary
// container — the bug pre-slice-39 was that
// `Serializer::TypeSerializer::visitNarrowedAnyType` had a
// `llvm_unreachable("serialisation of narrowed Any not yet
// implemented")`, so any public API mentioning `A | B` aborted
// the compiler at module-emission time.

public typealias V = Int | String

public func make(_ k: Int) -> V {
    k % 2 == 0 ? "even\(k)" : k
}

public func describe(_ v: V) -> String {
    switch v {
    case let i as Int: return "lib-int \(i)"
    case let s as String: return "lib-str \(s)"
    }
}

// Narrowed-Any embedded in a public struct's stored property —
// exercises the alternative-list serialisation through a nominal
// container.
public struct Bag {
    public let value: V
    public init(_ value: V) { self.value = value }
}

// Nested narrowed-Any in a generic position — `Array<V>` and
// `Optional<V>` flow the alternatives list through generic
// argument substitution at deserialisation.
public func first(_ xs: [V]) -> V? { xs.first }

// Typed throws over a narrowed-Any in a public signature — the
// failure path crosses a module boundary, so the deserialised
// thrown-error type must match the serialised one bit-for-bit.
public enum NetErr: Error { case down }
public enum DBErr: Error { case timeout }
public func fetch(_ k: Int) throws(NetErr | DBErr) -> V {
    switch k {
    case 0: throw NetErr.down
    case 1: throw DBErr.timeout
    default: return make(k)
    }
}

//--- Driver.swift
// Slice 39 driver: imports the Lib module that publicly exposes
// narrowed-Any and exercises every API surface.
import Lib

// Ensure each call returns the expected values; failures go to
// stderr so test.sh's grep can spot them, exit 1 trips `set -e`.
func check(_ ok: Bool, _ what: String) {
    if !ok {
        FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
        exit(1)
    }
}

import Foundation

// 1. Top-level narrowed-Any return + per-leaf dispatch.
check(describe(make(7)) == "lib-int 7", "make(odd) → Int via narrowed-Any")
check(describe(make(8)) == "lib-str even8", "make(even) → String via narrowed-Any")

// 2. Public struct field carrying narrowed-Any.
let b1 = Bag(99 as V)
let b2 = Bag("hi" as V)
check(describe(b1.value) == "lib-int 99", "Bag.value Int")
check(describe(b2.value) == "lib-str hi", "Bag.value String")

// 3. Optional<V> via Array.first.
let xs: [V] = [1, "x"]
if let head = first(xs) {
    check(describe(head) == "lib-int 1", "Array.first via [V]")
} else {
    check(false, "first should not return nil")
}
check(first([]) == nil, "first of empty")

// 4. Cross-module typed-throws over narrowed-Any error.
do {
    let v = try fetch(2)
    check(describe(v) == "lib-str even2", "fetch(2) succeeds")
} catch { check(false, "fetch(2) should not throw") }

do {
    _ = try fetch(0)
    check(false, "fetch(0) should throw")
} catch let e as NetErr {
    check(e == .down, "fetch(0) throws NetErr.down")
} catch { check(false, "fetch(0) wrong error \(error)") }

do {
    _ = try fetch(1)
    check(false, "fetch(1) should throw")
} catch let e as DBErr {
    check(e == .timeout, "fetch(1) throws DBErr.timeout")
} catch { check(false, "fetch(1) wrong error \(error)") }

print("driver: all 9 checks passed")
