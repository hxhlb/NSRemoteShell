import CoreGraphics
import Foundation
@testable import NSRemoteShell
import Testing

struct ShellTests {
    @Test
    func shellPtySizeChange() async throws {
        try await withSerialTestLock {
            print("testShellPtySizeChange: start")
            _ = try await withConnectedShell { shell in
                let sizeProvider = TerminalSizeProvider(CGSize(width: 80, height: 24))
                let output = OutputBuffer()
                let deadline = Date().addingTimeInterval(10)
                let phase = AtomicInt(0)

                try await shell.openShell(
                    terminalType: "xterm-256color",
                    terminalSize: { sizeProvider.get() },
                    writeData: {
                        switch phase.get() {
                        case 0:
                            phase.set(1)
                            return "stty size\n"
                        case 2:
                            phase.set(3)
                            return "sleep 0.2\nstty size\nexit\n"
                        default:
                            return nil
                        }
                    },
                    onOutput: {
                        output.append($0)

                        let normalized = normalizeShellOutput(output.value())
                        if phase.get() == 1, containsTerminalSize(normalized, rows: 24, columns: 80) {
                            print("testShellPtySizeChange: changing size to 120x40")
                            sizeProvider.set(CGSize(width: 120, height: 40))
                            phase.set(2)
                        }
                    },
                    shouldContinue: { Date() < deadline }
                )

                let result = output.value()
                let normalized = normalizeShellOutput(result)
                print("testShellPtySizeChange: output=\(result.utf8.count) bytes")
                print("testShellPtySizeChange: normalized output:\n\(normalized)")

                #expect(containsTerminalSize(normalized, rows: 24, columns: 80))
                #expect(containsTerminalSize(normalized, rows: 40, columns: 120))
            }
        }
    }

    @Test
    func shellMultiRoundOutput() async throws {
        try await withSerialTestLock {
            print("testShellMultiRoundOutput: start")
            _ = try await withConnectedShell { shell in
                let rounds = 5
                var commands: [String] = []
                var markers: [String] = []
                for i in 1 ... rounds {
                    let marker = "ROUND_\(i)_" + UUID().uuidString.prefix(8)
                    markers.append(marker)
                    commands.append("echo '\(marker)'\n")
                    commands.append("sleep 0.2\n")
                }
                commands.append("exit\n")

                let input = InputQueue(commands)
                let output = OutputBuffer()
                let deadline = Date().addingTimeInterval(15)

                try await shell.openShell(
                    terminalType: "xterm-256color",
                    terminalSize: { CGSize(width: 80, height: 24) },
                    writeData: { input.pop() },
                    onOutput: { output.append($0) },
                    shouldContinue: { Date() < deadline }
                )

                let result = output.value()
                print("testShellMultiRoundOutput: output=\(result.utf8.count) bytes")

                for (i, marker) in markers.enumerated() {
                    let found = result.contains(marker)
                    print("testShellMultiRoundOutput: round \(i + 1) marker found=\(found)")
                    #expect(found)
                }
            }
        }
    }

    @Test
    func shellCtrlC() async throws {
        try await withSerialTestLock {
            print("testShellCtrlC: start")
            _ = try await withConnectedShell { shell in
                let ctrlCSent = AtomicBool(false)
                let input = InputQueue([
                    "while true; do echo running; sleep 0.2; done\n",
                ])
                let output = OutputBuffer()
                let deadline = Date().addingTimeInterval(10)
                let startTime = Date()

                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    print("testShellCtrlC: sending Ctrl+C")
                    ctrlCSent.set(true)
                }

                do {
                    try await shell.openShell(
                        terminalType: "xterm-256color",
                        terminalSize: { CGSize(width: 80, height: 24) },
                        writeData: {
                            if let data = input.pop() {
                                return data
                            }
                            if ctrlCSent.get() {
                                return "\u{03}"
                            }
                            return nil
                        },
                        onOutput: { output.append($0) },
                        shouldContinue: {
                            let elapsed = Date().timeIntervalSince(startTime)
                            if elapsed > 3 {
                                return false
                            }
                            let result = output.value()
                            if ctrlCSent.get(), result.contains("running") {
                                let afterCtrl = result.components(separatedBy: "running").count
                                return afterCtrl < 20
                            }
                            return Date() < deadline
                        }
                    )
                } catch {
                    if ctrlCSent.get(),
                       let shellError = error as? RemoteShellError,
                       case let .libssh2Error(_, message) = shellError,
                       message.contains("transport read")
                    {
                        print("testShellCtrlC: ignoring transport read after Ctrl+C")
                    } else {
                        throw error
                    }
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let result = output.value()
                print("testShellCtrlC: elapsed=\(elapsed)s output=\(result.utf8.count) bytes")

                #expect(result.contains("running"))
                #expect(elapsed < 8)
            }
        }
    }
}

private func normalizeShellOutput(_ text: String) -> String {
    let stripped = stripANSIEscapeSequences(from: text)
    return stripped.unicodeScalars
        .filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        .map(String.init)
        .joined()
}

private func stripANSIEscapeSequences(from text: String) -> String {
    let characters = Array(text)
    var result = String()
    var index = 0

    while index < characters.count {
        let character = characters[index]
        if character == "\u{1B}" {
            index += 1
            guard index < characters.count else { break }

            switch characters[index] {
            case "[":
                index += 1
                while index < characters.count {
                    guard let scalar = characters[index].unicodeScalars.first?.value else {
                        index += 1
                        continue
                    }
                    index += 1
                    if scalar >= 0x40, scalar <= 0x7E {
                        break
                    }
                }
            case "]":
                index += 1
                while index < characters.count {
                    if characters[index] == "\u{07}" {
                        index += 1
                        break
                    }
                    if characters[index] == "\u{1B}",
                       index + 1 < characters.count,
                       characters[index + 1] == "\\"
                    {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
            continue
        }

        result.append(character)
        index += 1
    }

    return result
}

private func containsTerminalSize(_ text: String, rows: Int, columns: Int) -> Bool {
    let tokens = text.split(whereSeparator: \.isWhitespace)
    for (first, second) in zip(tokens, tokens.dropFirst()) {
        if first == "\(rows)", second == "\(columns)" {
            return true
        }
    }
    return false
}
