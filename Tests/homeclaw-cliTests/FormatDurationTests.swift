import Testing
@testable import homeclaw_cli

@Suite("CreateAutomation.formatDuration")
struct FormatDurationTests {
    @Test("seconds-only under one minute")
    func secondsOnly() {
        #expect(CreateAutomation.formatDuration(1) == "1s")
        #expect(CreateAutomation.formatDuration(45) == "45s")
        #expect(CreateAutomation.formatDuration(59) == "59s")
    }

    @Test("exact minute boundary")
    func exactMinute() {
        #expect(CreateAutomation.formatDuration(60) == "1m")
        #expect(CreateAutomation.formatDuration(120) == "2m")
        #expect(CreateAutomation.formatDuration(300) == "5m")
    }

    @Test("minutes with leftover seconds")
    func minutesAndSeconds() {
        #expect(CreateAutomation.formatDuration(61) == "1m1s")
        #expect(CreateAutomation.formatDuration(125) == "2m5s")
        #expect(CreateAutomation.formatDuration(3599) == "59m59s")
    }

    @Test("exact hour boundary")
    func exactHour() {
        #expect(CreateAutomation.formatDuration(3600) == "1h")
        #expect(CreateAutomation.formatDuration(7200) == "2h")
    }

    @Test("hours with leftover minutes")
    func hoursAndMinutes() {
        #expect(CreateAutomation.formatDuration(3660) == "1h1m")
        #expect(CreateAutomation.formatDuration(5400) == "1h30m")
        #expect(CreateAutomation.formatDuration(7500) == "2h5m")
    }

    @Test("residual seconds collapse at hour scale")
    func hoursDropResidualSeconds() {
        // Past 1h the format intentionally renders hours + minutes only;
        // a stray 1s within an hour-scale duration should not appear.
        #expect(CreateAutomation.formatDuration(3661) == "1h1m")
    }

    @Test("maximum allowed value (24h)")
    func maxValue() {
        #expect(CreateAutomation.formatDuration(86400) == "24h")
    }
}
