import Foundation
@testable import KlyndroKit
import Testing

@Suite("Toolchain probe")
struct ToolchainProbeTests {
    @Test("finds a tool that exists in a supplied search path")
    func findsExistingTool() throws {
        // `/bin` always contains `sh` on macOS; this exercises the lookup without
        // depending on Homebrew being installed.
        let path = ToolchainProbe.locate("sh", searchPath: "/bin")
        #expect(path == "/bin/sh")
    }

    @Test("returns nil for a tool that does not exist")
    func missingToolIsNil() {
        let path = ToolchainProbe.locate(
            "klyndro-definitely-not-installed",
            searchPath: "/bin:/usr/bin"
        )
        #expect(path == nil)
    }

    @Test("searches multiple directories and prefers the first match")
    func firstMatchWins() {
        let path = ToolchainProbe.locate("sh", searchPath: "/nonexistent:/bin")
        #expect(path == "/bin/sh")
    }

    @Test("keeps only the first non-empty line of version output")
    func versionSummary() {
        let output = "\n  scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>  \nDependencies:\n"
        #expect(
            ToolchainProbe.summarizeVersionOutput(output)
                == "scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>"
        )
    }

    @Test("caps absurdly long version output")
    func versionSummaryIsCapped() {
        let output = String(repeating: "x", count: 500)
        let summary = ToolchainProbe.summarizeVersionOutput(output)
        #expect(summary?.count == 120)
    }

    @Test("reports no version for empty output")
    func emptyOutput() {
        #expect(ToolchainProbe.summarizeVersionOutput("\n\n   \n") == nil)
    }

    @Test("probe reports adb and scrcpy entries with an evaluation time")
    func probeProducesReport() async {
        let report = await ToolchainProbe.probe()
        #expect(report.tools.map(\.name) == ["adb", "scrcpy"])
        #expect(report.generatedAt.timeIntervalSinceNow > -60)
        // Every reported tool is either found with a path, or explicitly not found.
        for tool in report.tools {
            #expect(tool.isAvailable == (tool.path != nil))
        }
    }
}
