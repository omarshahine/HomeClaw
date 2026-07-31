import Testing
@testable import homeclaw_cli

// Fills the gaps in the existing automation-helper coverage. CreateTimeTests
// already covers validateTimeOfDaySpec / parseWeekdays / parse{Condition,Action}Row,
// and FormatDurationTests covers formatDuration. The two helpers below were
// previously untested:
//   - formatWeekdays: the inverse of parseWeekdays, used to render list/get output
//   - validateTimeSpec: the --time-after / --time-before parser. Since #81 it shares
//     its grammar with the --time parser (validateTimeOfDaySpec now delegates to it),
//     so both clock times and sun events are accepted.

// MARK: - formatWeekdays (HomeKit weekday numbers → label)

@Suite("CreateAutomation.formatWeekdays")
struct FormatWeekdaysTests {
    @Test("single days map to their three-letter names (1=Sun … 7=Sat)")
    func singleDays() {
        #expect(CreateAutomation.formatWeekdays([1]) == "Sun")
        #expect(CreateAutomation.formatWeekdays([2]) == "Mon")
        #expect(CreateAutomation.formatWeekdays([7]) == "Sat")
    }

    @Test("multiple days join in the order given, comma-separated")
    func multipleDays() {
        #expect(CreateAutomation.formatWeekdays([2, 3, 4, 5, 6]) == "Mon,Tue,Wed,Thu,Fri")
        #expect(CreateAutomation.formatWeekdays([1, 7]) == "Sun,Sat")
    }

    @Test("round-trips with parseWeekdays")
    func roundTrip() throws {
        let nums = try CreateAutomation.parseWeekdays("mon,wed,fri")
        #expect(CreateAutomation.formatWeekdays(nums) == "Mon,Wed,Fri")
    }

    @Test("out-of-range numbers are dropped, not rendered as garbage")
    func outOfRangeDropped() {
        #expect(CreateAutomation.formatWeekdays([0, 8, 99]) == "")
        #expect(CreateAutomation.formatWeekdays([2, 8, 3]) == "Mon,Tue")
    }

    @Test("empty input yields an empty label")
    func empty() {
        #expect(CreateAutomation.formatWeekdays([]) == "")
    }
}

// MARK: - validateTimeSpec (the --time-after / --time-before parser)

@Suite("CreateAutomation.validateTimeSpec")
struct ValidateTimeSpecTests {
    @Test("bare sun events accepted and lowercased")
    func bareSunEvents() throws {
        #expect(try CreateAutomation.validateTimeSpec("sunrise", flag: "--time-after") == "sunrise")
        #expect(try CreateAutomation.validateTimeSpec("SUNSET", flag: "--time-after") == "sunset")
    }

    @Test("signed offsets accepted")
    func signedOffsets() throws {
        #expect(try CreateAutomation.validateTimeSpec("sunset-30", flag: "--time-before") == "sunset-30")
        #expect(try CreateAutomation.validateTimeSpec("sunrise+15", flag: "--time-before") == "sunrise+15")
        #expect(try CreateAutomation.validateTimeSpec("sunrise+0", flag: "--time-after") == "sunrise+0")
    }

    @Test("whitespace inside a sun offset is tolerated and normalized away")
    func spacedOffsets() throws {
        // The pre-#81 socket-side condition parser trimmed the leading side of the
        // offset, so `sunset -30` reached HomeKit fine via MCP (which forwards raw
        // strings unvalidated). Unifying the grammar must not regress that, and the
        // value we put on the wire should be canonical either way.
        #expect(try CreateAutomation.validateTimeSpec("sunset -30", flag: "--time-after") == "sunset-30")
        #expect(try CreateAutomation.validateTimeSpec("sunrise +15", flag: "--time-before") == "sunrise+15")
        #expect(try CreateAutomation.validateTimeSpec("sunset - 30", flag: "--time-after") == "sunset-30")
        #expect(try CreateAutomation.validateTimeSpec("sunset- 30", flag: "--time-after") == "sunset-30")
        #expect(try CreateAutomation.validateTimeSpec("  SUNRISE + 15  ", flag: "--time") == "sunrise+15")
    }

    @Test("offset at the 1440-minute cap accepted, beyond it rejected")
    func offsetCap() throws {
        #expect(try CreateAutomation.validateTimeSpec("sunset+1440", flag: "--time-after") == "sunset+1440")
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("sunset+1441", flag: "--time-after")
        }
    }

    @Test("HH:MM clock times accepted as conditions (#81)")
    func clockTimeAccepted() throws {
        // Gating a sensor automation to a fixed time-of-day window is the whole
        // point of #81 — `--time-after 07:00 --time-before 20:30`.
        #expect(try CreateAutomation.validateTimeSpec("07:00", flag: "--time-after") == "07:00")
        #expect(try CreateAutomation.validateTimeSpec("20:30", flag: "--time-before") == "20:30")
        #expect(try CreateAutomation.validateTimeSpec("00:00", flag: "--time-after") == "00:00")
        #expect(try CreateAutomation.validateTimeSpec("23:59", flag: "--time-before") == "23:59")
        #expect(try CreateAutomation.validateTimeSpec("  09:15  ", flag: "--time-after") == "09:15")
    }

    @Test("clock times keep the strict two-digit / in-range rules of --time")
    func clockTimeStrictness() {
        // Same rules as validateTimeOfDaySpec: '6:30' must not be silently widened,
        // and '12:5' must not become '12:50'.
        for bad in ["6:30", "12:5", "12:345", "25:00", "24:00", "12:60", "12:ab", ":30", "12:", ":"] {
            #expect(throws: (any Error).self) {
                _ = try CreateAutomation.validateTimeSpec(bad, flag: "--time-after")
            }
        }
    }

    @Test("unknown sun event rejected")
    func unknownEvent() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("noon", flag: "--time-after")
        }
    }

    @Test("offset missing sign or magnitude rejected")
    func malformedOffset() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("sunset30", flag: "--time-after")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("sunrise+", flag: "--time-after")
        }
    }

    @Test("empty / whitespace input rejected")
    func emptyRejected() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("", flag: "--time-after")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("   ", flag: "--time-after")
        }
    }

    @Test("the error message names the offending flag for actionable CLI feedback")
    func errorNamesFlag() {
        do {
            _ = try CreateAutomation.validateTimeSpec("noon", flag: "--time-before")
            Issue.record("expected validateTimeSpec to throw")
        } catch {
            #expect(String(describing: error).contains("--time-before"))
        }
    }
}
