import Foundation

/// What to tell the user when mirroring cannot start because no usable phone is attached.
///
/// Klyndro never switches debugging on for the user: both USB debugging and Wireless debugging are
/// explicit choices made on the phone, so the app explains them instead.
public struct MirroringGuidance: Sendable, Equatable {
    public var title: String
    public var message: String

    public static func make(devices: [AdbDevice]) -> MirroringGuidance {
        // A phone adb can see but not use is the most specific thing to report.
        if let blocked = devices.first(where: { !$0.isUsable }), let problem = blocked.actionableProblem {
            return MirroringGuidance(title: "The phone is not ready for mirroring", message: problem)
        }

        return MirroringGuidance(
            title: "Turn on debugging to mirror the screen",
            message: """
            Mirroring needs one of these on the phone:

            Wi-Fi: turn on Wireless debugging (Settings > Developer options). If this Mac has not been authorised by adb yet, connect via USB once first. Both devices must be on the same Wi-Fi network.

            USB: connect the cable and turn on USB debugging (Settings > Developer options), then accept the prompt on the phone.

            Klyndro never turns these on by itself.
            """
        )
    }
}
