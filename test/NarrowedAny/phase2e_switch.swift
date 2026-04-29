// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Phase 2b.E: switch over narrowed `Any` is exhaustive when every
// declared alternative has a matching `case _ as Alt:` arm. No
// `default` clause needed once the closed conformer set is covered.

// MARK: 1. Two-way exhaustive — no `default`, no warnings, runs.
do {
    let v: Int | String = 42
    var hit = ""
    switch v {
    case let n as Int:    hit = "int(\(n))"
    case let s as String: hit = "str(\(s))"
    }
    assert(hit == "int(42)")
}

// MARK: 2. Three-way exhaustive — declaration-order leaves all covered.
do {
    let v: Int | String | Double = 3.14
    var hit = ""
    switch v {
    case let n as Int:    hit = "int(\(n))"
    case let s as String: hit = "str(\(s))"
    case let d as Double: hit = "dbl(\(d))"
    }
    assert(hit == "dbl(3.14)")
}

// MARK: 3. Reordered cases still exhaustive — order of cases doesn't
// have to match alternation declaration order, just cover the set.
do {
    let v: Int | String | Double = "hi"
    var hit = ""
    switch v {
    case let d as Double: hit = "dbl(\(d))"
    case let s as String: hit = "str(\(s))"
    case let n as Int:    hit = "int(\(n))"
    }
    assert(hit == "str(hi)")
}

// MARK: 4. Default is allowed (always was) and still works when
// alternatives aren't fully covered.
do {
    let v: Int | String | Double = 3.14
    var hit = ""
    switch v {
    case let n as Int: hit = "int(\(n))"
    default:           hit = "other"
    }
    assert(hit == "other")
}

// MARK: 5. Catch-all uses `default:` — `case _:` is not treated as
// exhaustive by Swift (matches plain-`Any` behaviour).
do {
    let v: Int | String = "fallthrough"
    var hit = ""
    switch v {
    case let n as Int: hit = "int(\(n))"
    default:           hit = "wild"
    }
    assert(hit == "wild")
}
