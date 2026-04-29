// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// Slice 35 + slice 13/14 composition test: Codable round-trip
// with an enum leaf that has a raw value.
//
// Verifies the untagged Codable wire format (per slice 13/14)
// honours the enum's own Codable conformance — for a String-raw
// enum like `enum Status: String, Codable { case active, ... }`,
// `Wrap(value: V.active)` encodes as `{"value":"active"}` (the
// raw value), and decoding that JSON back returns a value whose
// dynamic type is the enum case again.
//
// Companion to test-phase3f-codable-nested.swift; lives in its
// own file because cumulating the witness tables of this test
// plus the existing Codable sections trips a JIT-mode Foundation
// stale-optional fatalError; the two files run fine on their own.

import Foundation

enum Status: String, Codable {
    case active, inactive, pending
}

typealias V = Status | Int

struct Wrap: Codable {
    var value: Status | Int    // explicit shape to keep narrowed-Any visible in AST dump
}

do {
    let original = Wrap(value: .active)
    let data = try JSONEncoder().encode(original)
    let json = String(data: data, encoding: .utf8) ?? ""
    assert(json == #"{"value":"active"}"#, "enum-leaf encode: got \(json)")

    let decoded = try JSONDecoder().decode(Wrap.self, from: data)
    assert(decoded.value as? Status == .active,
           "enum-leaf decode: round-tripped to .active")
}

do {
    let original = Wrap(value: 42)
    let data = try JSONEncoder().encode(original)
    let json = String(data: data, encoding: .utf8) ?? ""
    assert(json == #"{"value":42}"#, "Int-leaf encode: got \(json)")

    let decoded = try JSONDecoder().decode(Wrap.self, from: data)
    assert(decoded.value as? Int == 42,
           "Int-leaf decode: round-tripped to 42")
}

do {
    // Try-each-leaf in declaration order: Status first, then Int.
    // A wire value `"pending"` decodes to .pending (Status raw value),
    // but the wire `"42"` (string) couldn't decode as Status (not in
    // raw-value set) so it would fall through to Int — except 42 in
    // JSON is a number, not a string; the wire shape disambiguates.
    let json = #"{"value":"pending"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Wrap.self, from: json)
    assert(decoded.value as? Status == .pending,
           "untagged decode: \"pending\" → .pending")
}
