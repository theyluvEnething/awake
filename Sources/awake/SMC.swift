import Foundation
import IOKit
import Synchronization

/// The SMC's battery temperature sensors, read without root. macOS 27 no longer publishes the
/// battery's Temperature in the IORegistry, and the heat guard needs it.
enum SMC {
    private static let cache = Mutex<(at: Double, celsius: Double?)?>(nil)

    /// The hottest battery sensor in degrees Celsius, or nil when the Mac has none. The battery warms
    /// slowly and the menu takes snapshots every few seconds, so a reading is reused for 30 seconds.
    static func batteryTemperature() -> Double? {
        let now = Date().timeIntervalSince1970
        if let cached = cache.withLock({ $0 }), (0..<30).contains(now - cached.at) { return cached.celsius }
        let celsius = readBatteryTemperature()
        cache.withLock { $0 = (now, celsius) }
        return celsius
    }

    private static func readBatteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        defer { IOServiceClose(connection) }
        return ["TB0T", "TB1T", "TB2T", "TB3T"].compactMap { read($0, connection) }.max()
    }

    /// A temperature from the SMC's bytes: Apple silicon reports little-endian floats ("flt "),
    /// Intel Macs big-endian signed 8.8 fixed point ("sp78"). Implausible values count as missing.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch (type, bytes.count) {
        case ("flt ", 4):
            value = Double(Float(bitPattern: bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }))
        case ("sp78", 2):
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
        return (-20.0..<100).contains(value) ? value : nil
    }

    /// The kernel's SMCParamStruct: 80 bytes, with C's padding spelled out.
    struct Param {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static func read(_ key: String, _ connection: io_connect_t) -> Double? {
        var info = Param()
        info.key = fourCharacterCode(key)
        info.command = 9 // key info
        guard let described = call(&info, connection) else { return nil }
        var request = Param()
        request.key = info.key
        request.size = described.size
        request.command = 5 // read bytes
        guard described.size <= 32, let answer = call(&request, connection) else { return nil }
        let bytes = withUnsafeBytes(of: answer.bytes) { Array($0.prefix(Int(described.size))) }
        return decode(type: string(described.type), bytes: bytes)
    }

    private static func call(_ input: inout Param, _ connection: io_connect_t) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func fourCharacterCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}
