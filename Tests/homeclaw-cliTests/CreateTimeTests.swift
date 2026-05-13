import Testing
@testable import homeclaw_cli

// MARK: - validateTimeOfDaySpec (the --time parser for `create-time`)
//
// These exercise the CLI-layer parser specifically. The HomeKit-side `TimeSpec.parse`
// in HomeKitManager is the source of truth and re-validates whatever the socket
// receives, but the CLI parser owns the user-facing error messages — keeping it
// strict prevents ambiguous values like `12:5` from reaching the socket layer.

@Suite("CreateTimeAutomation.validateTimeOfDaySpec — HH:MM")
struct ValidateTimeOfDaySpecHHMMTests {
    @Test("valid clock times round-trip with two-digit canonical form")
    func validClockTimes() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("00:00") == "00:00")
        #expect(try CreateAutomation.validateTimeOfDaySpec("06:30") == "06:30")
        #expect(try CreateAutomation.validateTimeOfDaySpec("12:34") == "12:34")
        #expect(try CreateAutomation.validateTimeOfDaySpec("23:59") == "23:59")
    }

    @Test("whitespace around input is tolerated, but the canonical form is trimmed")
    func whitespaceTolerated() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("  09:15  ") == "09:15")
    }

    @Test("hour > 23 rejected")
    func badHour() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("25:00")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("24:00")
        }
    }

    @Test("minute > 59 rejected")
    func badMinute() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("12:60")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("12:99")
        }
    }

    @Test("single-digit hour rejected — '6:30' could be 6 or 60 to a casual reader")
    func singleDigitHour() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("6:30")
        }
    }

    @Test("single-digit minute rejected — '12:5' must not silently become '12:50'")
    func singleDigitMinute() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("12:5")
        }
    }

    @Test("three-digit minute rejected")
    func threeDigitMinute() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("12:345")
        }
    }

    @Test("missing colon rejected — '1234' must not be interpreted as HH:MM")
    func missingColon() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("1234")
        }
    }

    @Test("non-numeric components rejected")
    func nonNumeric() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("ab:cd")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("12:ab")
        }
    }

    @Test("empty hour or minute rejected")
    func emptyComponent() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec(":30")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("12:")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec(":")
        }
    }
}

@Suite("CreateTimeAutomation.validateTimeOfDaySpec — sunrise/sunset")
struct ValidateTimeOfDaySpecSunTests {
    @Test("bare sunrise/sunset accepted and lowercased")
    func bareSunEvents() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunrise") == "sunrise")
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunset") == "sunset")
        #expect(try CreateAutomation.validateTimeOfDaySpec("Sunrise") == "sunrise")
        #expect(try CreateAutomation.validateTimeOfDaySpec("SUNSET") == "sunset")
    }

    @Test("positive offsets accepted")
    func positiveOffsets() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunrise+15") == "sunrise+15")
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunset+60") == "sunset+60")
    }

    @Test("negative offsets accepted")
    func negativeOffsets() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunset-30") == "sunset-30")
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunrise-45") == "sunrise-45")
    }

    @Test("zero-minute offset accepted")
    func zeroOffset() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunrise+0") == "sunrise+0")
    }

    @Test("offset exactly at the 1440-minute cap accepted")
    func maxOffsetAccepted() throws {
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunrise+1440") == "sunrise+1440")
        #expect(try CreateAutomation.validateTimeOfDaySpec("sunset-1440") == "sunset-1440")
    }

    @Test("offset > 1440 rejected — almost certainly a typo, user probably wanted --days")
    func offsetOutOfRange() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("sunrise+1500")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("sunset-9999")
        }
    }

    @Test("offset missing sign rejected — must start with + or -")
    func missingSign() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("sunset30")
        }
    }

    @Test("offset present but missing numeric magnitude rejected")
    func missingMagnitude() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("sunrise+")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("sunset-")
        }
    }

    @Test("unknown sun event rejected — 'noon' and 'midnight' are not HomeKit primitives")
    func unknownSunEvent() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("noon")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("midnight")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("dawn")
        }
    }

    @Test("empty input rejected")
    func emptyInput() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.validateTimeOfDaySpec("   ")
        }
    }
}

// MARK: - parseWeekdays (the --days parser shared by create and create-time)

@Suite("CreateAutomation.parseWeekdays")
struct ParseWeekdaysTests {
    @Test("named days accepted in any case")
    func namedDays() throws {
        #expect(try CreateAutomation.parseWeekdays("mon,tue,wed,thu,fri") == [2, 3, 4, 5, 6])
        #expect(try CreateAutomation.parseWeekdays("Sun,Sat") == [1, 7])
        #expect(try CreateAutomation.parseWeekdays("MONDAY,FRIDAY") == [2, 6])
    }

    @Test("numeric days accepted")
    func numericDays() throws {
        #expect(try CreateAutomation.parseWeekdays("1,2,3") == [1, 2, 3])
        #expect(try CreateAutomation.parseWeekdays("7,5,3,1") == [1, 3, 5, 7])
    }

    @Test("mixed named + numeric accepted")
    func mixedDays() throws {
        #expect(try CreateAutomation.parseWeekdays("mon,5,fri") == [2, 5, 6])
    }

    @Test("duplicates collapse and result is sorted")
    func duplicatesAndOrder() throws {
        #expect(try CreateAutomation.parseWeekdays("fri,mon,fri,2") == [2, 6])
        #expect(try CreateAutomation.parseWeekdays("3,3,3") == [3])
    }

    @Test("whitespace around tokens tolerated")
    func whitespaceTolerated() throws {
        #expect(try CreateAutomation.parseWeekdays(" mon , tue , wed ") == [2, 3, 4])
    }

    @Test("invalid token rejected")
    func invalidToken() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseWeekdays("mon,xxx,fri")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseWeekdays("mon,8,fri")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseWeekdays("0")
        }
    }
}

// MARK: - parseConditionRow (the --condition parser shared by create and create-time)

@Suite("CreateAutomation.parseConditionRow")
struct ParseConditionRowTests {
    @Test("three colon-separated parts accepted")
    func validRow() throws {
        let parsed = try CreateAutomation.parseConditionRow("Front Door:contact_state:0")
        #expect(parsed["accessory"] == "Front Door")
        #expect(parsed["property"] == "contact_state")
        #expect(parsed["value"] == "0")
    }

    @Test("whitespace trimmed inside parts")
    func whitespaceTrimmed() throws {
        let parsed = try CreateAutomation.parseConditionRow("  Foo  :  bar  :  baz  ")
        #expect(parsed["accessory"] == "Foo")
        #expect(parsed["property"] == "bar")
        #expect(parsed["value"] == "baz")
    }

    @Test("value containing colons preserved via maxSplits=2")
    func valueWithColons() throws {
        let parsed = try CreateAutomation.parseConditionRow("Sensor:rgb:255:128:0")
        #expect(parsed["accessory"] == "Sensor")
        #expect(parsed["property"] == "rgb")
        #expect(parsed["value"] == "255:128:0")
    }

    @Test("fewer than 3 parts rejected")
    func tooFewParts() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseConditionRow("Foo:bar")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseConditionRow("Foo")
        }
    }

    @Test("empty parts rejected")
    func emptyParts() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseConditionRow(":bar:baz")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseConditionRow("foo::baz")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseConditionRow("foo:bar:")
        }
    }
}

// MARK: - parseActionRow (the --action parser shared by create and create-time)

@Suite("CreateAutomation.parseActionRow")
struct ParseActionRowTests {
    @Test("three colon-separated parts accepted")
    func validRow() throws {
        let parsed = try CreateAutomation.parseActionRow("Light:power:1")
        #expect(parsed["accessory"] == "Light")
        #expect(parsed["property"] == "power")
        #expect(parsed["value"] == "1")
    }

    @Test("whitespace trimmed inside parts")
    func whitespaceTrimmed() throws {
        let parsed = try CreateAutomation.parseActionRow("  Light  :  power  :  1  ")
        #expect(parsed["accessory"] == "Light")
        #expect(parsed["property"] == "power")
        #expect(parsed["value"] == "1")
    }

    @Test("value containing colons preserved via maxSplits=2")
    func valueWithColons() throws {
        let parsed = try CreateAutomation.parseActionRow("Sensor:rgb:255:128:0")
        #expect(parsed["accessory"] == "Sensor")
        #expect(parsed["property"] == "rgb")
        #expect(parsed["value"] == "255:128:0")
    }

    @Test("fewer than 3 parts rejected")
    func tooFewParts() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseActionRow("Light:power")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseActionRow("Light")
        }
    }

    @Test("empty parts rejected")
    func emptyParts() {
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseActionRow(":power:1")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseActionRow("Light::1")
        }
        #expect(throws: (any Error).self) {
            _ = try CreateAutomation.parseActionRow("Light:power:")
        }
    }
}
