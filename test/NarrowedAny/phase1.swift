// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Parser hook for `A | B` types. Phase-1-era smoke test that has been
// kept as a regression: leaf injection, plain `as?` against each leaf,
// switch with leaf-as patterns, three-arity flat form, and the nested
// form `(A | B) | C`.

// 1. Basic 2-arity injection
let v: Int | String = 42
assert(type(of: v) == Int.self)
assert(v as? Int == 42)
assert(v as? String == nil)

// 2. switch with leaf case patterns (default required because of desugar)
let w: Int | String = "hello"
var matched: String? = nil
switch w {
case let i as Int:    matched = "Int(\(i))"
case let s as String: matched = "Str(\(s))"
default:              matched = "other"
}
assert(matched == "Str(hello)")

// 3. Three-arity: parser produces a flat 3-element NarrowedAnyTypeRepr.
let x: Int | String | Double = 3.14
assert(x as? Int == nil)
assert(x as? String == nil)
assert(x as? Double == 3.14)

// 4. Nested form: inner narrowed-`Any` inside the outer one.
let y: (Int | String) | Bool = true
assert(y as? Bool == true)
assert(y as? Int == nil)
