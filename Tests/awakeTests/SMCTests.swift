import Testing
@testable import awake

struct SMCTests {
    @Test func theRequestMatchesTheKernelsEightyByteLayout() {
        #expect(MemoryLayout<SMC.Param>.size == 80)
        #expect(MemoryLayout<SMC.Param>.offset(of: \.size) == 28)
        #expect(MemoryLayout<SMC.Param>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMC.Param>.offset(of: \.command) == 42)
        #expect(MemoryLayout<SMC.Param>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMC.Param>.offset(of: \.bytes) == 48)
    }

    @Test(arguments: [
        ("flt ", [96, 102, 246, 65], 30.8),
        ("sp78", [0x1E, 0x80], 30.5),
        ("sp78", [0xFF, 0x00], -1.0),
    ] as [(String, [UInt8], Double)])
    func temperaturesDecode(type: String, bytes: [UInt8], celsius: Double) throws {
        let value = try #require(SMC.decode(type: type, bytes: bytes))
        #expect(abs(value - celsius) < 0.01)
    }

    @Test(arguments: [
        ("flt ", [0, 0, 200, 66]),
        ("flt ", [96, 102, 246]),
        ("ui16", [224, 11]),
    ] as [(String, [UInt8])])
    func implausibleOrUnknownReadingsCountAsMissing(type: String, bytes: [UInt8]) {
        #expect(SMC.decode(type: type, bytes: bytes) == nil)
    }
}
