// DictationTranscriptionLineTests.swift
// Fork: the dictation queue. Takes detached at their stop are transcribed
// one at a time, in the order they stopped, and a cancelled take neither
// holds up nor jumps the takes behind it.

import Foundation

@MainActor
func testDictationTranscriptionLine() async {
    await runSuite("Detached takes are transcribed one at a time, in the order they stopped") {
        let line = DictationTranscriptionLine()
        let log = LineEventLog()
        let firstGate = ParakeetAsyncInterleavingGate()
        let first = Task { @MainActor in
            await line.run { log.add("1 start"); await firstGate.wait(); log.add("1 end"); return 1 }
        }
        await settleLine()
        let second = Task { @MainActor in
            await line.run { log.add("2 start"); return 2 }
        }
        await settleLine()
        assertEqual(log.events, ["1 start"], "the second take waits while the first is transcribed")
        assertEqual(line.count, 2, "both takes are in line")

        await firstGate.open()
        let results = [await first.value, await second.value]
        assertEqual(results, [1, 2], "each take gets its own words")
        assertEqual(log.events, ["1 start", "1 end", "2 start"], "the second starts only after the first ends")
        assertEqual(line.count, 0, "the line is empty once both are done")
    }

    await runSuite("A cancelled take doesn't hold up or jump the takes behind it") {
        let line = DictationTranscriptionLine()
        let log = LineEventLog()
        let firstGate = ParakeetAsyncInterleavingGate()
        let first = Task { @MainActor in
            await line.run { log.add("1"); await firstGate.wait(); return "first" }
        }
        await settleLine()
        let second = Task { @MainActor in
            await line.run { () -> String in
                guard !Task.isCancelled else { log.add("2 cancelled"); return "" }
                log.add("2")
                return "second"
            }
        }
        let third = Task { @MainActor in
            await line.run { log.add("3"); return "third" }
        }
        await settleLine()
        second.cancel()
        await settleLine()
        assertEqual(log.events, ["1"], "the cancelled take still waits its turn; nothing jumps the first")

        await firstGate.open()
        let results = [await first.value, await second.value, await third.value]
        assertEqual(results, ["first", "", "third"])
        assertEqual(log.events, ["1", "2 cancelled", "3"], "the take behind the cancelled one still runs, in order")
    }
}

@MainActor
private final class LineEventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

/// Lets queued main-actor work run. Counts scheduler turns, not time.
@MainActor
private func settleLine() async {
    for _ in 0..<20 { await Task.yield() }
}
