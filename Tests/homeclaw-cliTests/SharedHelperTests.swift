import Foundation
import Testing
@testable import homeclaw_cli

// Tests for the cross-command helpers in OutputFormat.swift / JSONHelper.swift.
// These are pure functions reachable without a socket, and they gate every
// command (input sanitisation, --since parsing, JSON-vs-text selection), so a
// regression here would silently affect the whole CLI.

// MARK: - validateInput (control-character injection guard)

@Suite("validateInput")
struct ValidateInputTests {
    @Test("ordinary text passes")
    func ordinaryText() {
        #expect(validateInput("Front Door", label: "accessory") == nil)
        #expect(validateInput("lightbulb", label: "category") == nil)
        #expect(validateInput("72.5", label: "value") == nil)
        #expect(validateInput("", label: "name") == nil) // empty is not a control char; emptiness is checked elsewhere
    }

    @Test("common whitespace (tab, newline, CR) is allowed")
    func allowedWhitespace() {
        #expect(validateInput("a\tb", label: "x") == nil)
        #expect(validateInput("a\nb", label: "x") == nil)
        #expect(validateInput("a\r\nb", label: "x") == nil)
    }

    @Test("NUL byte rejected")
    func nulRejected() {
        let result = validateInput("evil\u{0000}name", label: "accessory")
        #expect(result != nil)
        #expect(result?.contains("accessory") == true)
        #expect(result?.contains("U+0000") == true)
    }

    @Test("escape and bell control chars rejected")
    func otherControlsRejected() {
        #expect(validateInput("\u{001B}[31m", label: "query") != nil) // ESC (ANSI injection)
        #expect(validateInput("ding\u{0007}", label: "query") != nil) // BEL
        #expect(validateInput("\u{0008}", label: "query") != nil)     // backspace
    }

    @Test("the offending codepoint is reported in hex")
    func reportsCodepoint() {
        #expect(validateInput("\u{001B}", label: "x")?.contains("U+001B") == true)
    }

    @Test("unicode above the control range passes (emoji, accents)")
    func highUnicodePasses() {
        #expect(validateInput("Café 🛋️", label: "name") == nil)
    }
}

// MARK: - parseSinceValue (the --since parser for events / webhook-log)

@Suite("parseSinceValue")
struct ParseSinceValueTests {
    @Test("ISO 8601 timestamp passes through verbatim")
    func isoPassThrough() throws {
        let iso = "2026-05-31T12:00:00Z"
        #expect(try parseSinceValue(iso) == iso)
    }

    @Test("hour / minute / day shorthands resolve to a past ISO instant")
    func durationShorthands() throws {
        // We can't assert an exact timestamp (it's relative to now), but the
        // result must be a parseable ISO 8601 string strictly in the past.
        for spec in ["1h", "30m", "2d", "90m"] {
            let out = try parseSinceValue(spec)
            let parsed = ISO8601DateFormatter().date(from: out)
            #expect(parsed != nil, "‘\(spec)’ should produce ISO output, got ‘\(out)’")
            if let parsed { #expect(parsed < Date()) }
        }
    }

    @Test("a longer duration resolves further into the past than a shorter one")
    func durationOrdering() throws {
        // #require (not `if let`) so the ordering assertion fails loudly rather
        // than vacuously passing if parseSinceValue ever emits a non-ISO string.
        let oneHour = try #require(ISO8601DateFormatter().date(from: try parseSinceValue("1h")))
        let oneDay = try #require(ISO8601DateFormatter().date(from: try parseSinceValue("24h")))
        #expect(oneDay < oneHour)
    }

    @Test("unrecognised format throws and names the offending value")
    func unrecognisedThrows() {
        for bad in ["yesterday", "1 hour", "h1", "", "5", "1w"] {
            #expect(throws: (any Error).self) {
                _ = try parseSinceValue(bad)
            }
        }
    }
}

// MARK: - shouldOutputJSON (flag > env > TTY precedence)

@Suite("shouldOutputJSON precedence")
struct ShouldOutputJSONTests {
    @Test("--json flag forces JSON regardless of env or TTY")
    func flagWins() {
        #expect(shouldOutputJSON(true, outputFormatEnv: nil, stdoutIsTTY: true) == true)
        #expect(shouldOutputJSON(true, outputFormatEnv: "text", stdoutIsTTY: true) == true)
    }

    @Test("OUTPUT_FORMAT=json forces JSON even on a TTY")
    func envJSONWins() {
        #expect(shouldOutputJSON(false, outputFormatEnv: "json", stdoutIsTTY: true) == true)
        #expect(shouldOutputJSON(false, outputFormatEnv: "JSON", stdoutIsTTY: true) == true) // case-insensitive
    }

    @Test("non-json env value is ignored")
    func envOtherIgnored() {
        // On a TTY with no flag and a non-json env, output stays human-readable.
        #expect(shouldOutputJSON(false, outputFormatEnv: "text", stdoutIsTTY: true) == false)
        #expect(shouldOutputJSON(false, outputFormatEnv: nil, stdoutIsTTY: true) == false)
    }

    @Test("piped stdout (not a TTY) defaults to JSON for agent consumption")
    func nonTTYDefaultsJSON() {
        #expect(shouldOutputJSON(false, outputFormatEnv: nil, stdoutIsTTY: false) == true)
    }
}
