import Testing
@testable import KlyndroKit

@Suite("Mirroring guidance")
struct MirroringGuidanceTests {
    @Test("no device explains both Wireless debugging and USB debugging")
    func noDevice() {
        let guidance = MirroringGuidance.make(devices: [])
        #expect(guidance.message.contains("Wireless debugging"))
        #expect(guidance.message.contains("USB debugging"))
        #expect(guidance.message.contains("never turns these on"))
    }

    @Test("an unauthorized phone gets the specific fix, not the generic text")
    func unauthorized() {
        let device = AdbDevice(serial: "AAA", state: .unauthorized, model: nil, transport: .usb)
        let guidance = MirroringGuidance.make(devices: [device])
        #expect(guidance.message == device.actionableProblem)
        #expect(!guidance.message.contains("Wireless debugging"))
    }

    @Test("a usable device alongside none falls back to the generic text")
    func usableOnlyIsGeneric() {
        let device = AdbDevice(serial: "AAA", state: .device, model: nil, transport: .usb)
        #expect(MirroringGuidance.make(devices: [device]).message.contains("Wireless debugging"))
    }
}
