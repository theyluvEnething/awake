import Foundation
import Testing
@testable import awake

@Suite struct HelperCommands {
    @Test func allowsExactlyFiveCommands() {
        #expect(Set(PowerCommand.allCases) == [
            .lidSleepOn, .lidSleepOff, .energyAutomatic, .energyLow, .energyHigh,
        ])
        #expect(PowerCommand.allCases.count == 5)
    }

    @Test(arguments: [
        (PowerCommand.lidSleepOn, "disablesleep 0", ["-a", "disablesleep", "0"]),
        (.lidSleepOff, "disablesleep 1", ["-a", "disablesleep", "1"]),
        (.energyAutomatic, "powermode 0", ["-b", "powermode", "0"]),
        (.energyLow, "powermode 1", ["-b", "powermode", "1"]),
        (.energyHigh, "powermode 2", ["-b", "powermode", "2"]),
    ])
    func mapsToFixedPmsetArguments(command: PowerCommand, rawValue: String, arguments: [String]) {
        #expect(command.rawValue == rawValue)
        #expect(PowerCommand(rawValue: rawValue) == command)
        #expect(command.arguments == arguments)
    }

    @Test func sleepDisabledMeansLidSleepOff() {
        #expect(PowerCommand(sleepDisabled: true) == .lidSleepOff)
        #expect(PowerCommand(sleepDisabled: false) == .lidSleepOn)
    }

    @Test(arguments: [
        (0, PowerCommand.energyAutomatic), (1, .energyLow), (2, .energyHigh),
    ])
    func mapsBatteryEnergyModes(mode: Int, command: PowerCommand) {
        #expect(PowerCommand(batteryEnergyMode: mode) == command)
    }

    @Test(arguments: [-1, 3, Int.max])
    func rejectsOtherBatteryEnergyModes(mode: Int) {
        #expect(PowerCommand(batteryEnergyMode: mode) == nil)
    }

    @Test(arguments: [
        #"{"command":"disablesleep 2"}"#,
        #"{"command":"powermode 3"}"#,
        #"{"command":"sleepnow"}"#,
        #"{"command":"disablesleep 0; rm -rf /"}"#,
        #"{"command":""}"#,
        #"{"command":"DISABLESLEEP 0"}"#,
        #"{"command":" disablesleep 0"}"#,
        #"{"command":0}"#,
        #"{}"#,
    ])
    func refusesRequestsOutsideTheAllowlist(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PowerRequest.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: PowerCommand.allCases)
    func requestsRoundTrip(command: PowerCommand) throws {
        let data = try JSONEncoder().encode(PowerRequest(command: command))
        let request = try JSONDecoder().decode(PowerRequest.self, from: data)
        #expect(request.command == command)
    }
}
