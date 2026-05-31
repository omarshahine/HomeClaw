import Testing
@testable import homeclaw_cli

// Fills the gaps in the existing automation-helper coverage. CreateTimeTests
// already covers validateTimeOfDaySpec / parseWeekdays / parse{Condition,Action}Row,
// and FormatDurationTests covers formatDuration. The two helpers below were
// previously untested:
//   - formatWeekdays: the inverse of parseWeekdays, used to render list/get output
//   - validateTimeSpec: the --time-after / --time-before parser (distinct from the
//     --time parser, which is validateTimeOfDaySpec and rejects HH:MM here)

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

    @Test("offset at the 1440-minute cap accepted, beyond it rejected")
    func offsetCap() throws {
        #expect(try CreateAutomation.validateTimeSpec("sunset+1440", flag: "--time-after") == "sunset+1440")
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("sunset+1441", flag: "--time-after")
        }
    }

    @Test("HH:MM is NOT a valid sun-relative spec (that's --time, not --time-after)")
    func clockTimeRejected() {
        // validateTimeSpec only accepts sunrise/sunset forms — a wall-clock time
        // belongs to validateTimeOfDaySpec. This guards against the two parsers
        // being accidentally swapped.
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeSpec("06:30", flag: "--time-after")
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
