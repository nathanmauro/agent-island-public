import Darwin
import Foundation
import IslandCore

/// Cold start for one rollout (files reach 200 MB): line 1 (session_meta) read separately and
/// capped, then a backward scan in `chunk`-sized blocks for the last task_started, then the
/// complete lines from there to the last newline.
public enum CodexColdStartScanner {
    static let taskStartedToken = Array(#""task_started""#.utf8)
    static let lineSearchWindow = 4_096

    /// - firstLine: line 1 without its newline, or nil when it is longer than `firstLineCap` or not finished.
    /// - resumeOffset: start of the last task_started line (or of line 2 when there is none).
    /// - tail: complete lines in [resumeOffset, endOffset), minus empty and over-long lines.
    /// - endOffset: just past the last "\n"; a trailing partial line is left for RolloutTailReader.
    public static func scan(url: URL, firstLineCap: Int = IslandTiming.codexFirstLineCap,
                            chunk: Int = IslandTiming.codexScanChunk) throws
        -> (firstLine: Data?, resumeOffset: UInt64, tail: [Data], endOffset: UInt64) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RolloutFileIO.posixError() }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw RolloutFileIO.posixError() }
        let size = UInt64(max(0, metadata.st_size))
        let blockSize = max(chunk, taskStartedToken.count)
        let maxLineBytes = IslandTiming.codexMaxLineBytes

        let endOffset = try lastLineEnd(descriptor, size: size, chunk: blockSize)
        guard endOffset > 0 else { return (nil, 0, [], 0) }
        let (firstLine, firstLineEnd) = try readFirstLine(descriptor, limit: endOffset, cap: firstLineCap,
                                                          step: min(blockSize, 65_536))
        let resumeOffset = try lastTaskStartedLineStart(descriptor, floor: firstLineEnd, end: endOffset,
                                                        chunk: blockSize, maxLineBytes: maxLineBytes) ?? firstLineEnd
        let tail = try completeLines(descriptor, from: resumeOffset, to: endOffset, chunk: blockSize,
                                     maxLineBytes: maxLineBytes)
        return (firstLine, resumeOffset, tail, endOffset)
    }

    static func lastLineEnd(_ descriptor: Int32, size: UInt64, chunk: Int) throws -> UInt64 {
        var end = size
        while end > 0 {
            let start = end - min(UInt64(chunk), end)
            let block = try RolloutFileIO.readExactly(descriptor, offset: start, count: Int(end - start))
            if let index = RolloutFileIO.lastIndex(of: 0x0A, in: block) {
                return start + UInt64(index) + 1
            }
            end = start
        }
        return 0
    }

    /// Returns line 1 (nil when longer than `cap`) and the offset just past its newline.
    /// `limit` always ends at a newline, so the loop finds one.
    static func readFirstLine(_ descriptor: Int32, limit: UInt64, cap: Int, step: Int) throws -> (Data?, UInt64) {
        var collected = Data()
        var overCap = false
        var position: UInt64 = 0
        while position < limit {
            let block = try RolloutFileIO.readExactly(descriptor, offset: position,
                                                      count: Int(min(UInt64(step), limit - position)))
            if block.isEmpty { break }
            if let index = RolloutFileIO.firstIndex(of: 0x0A, in: block) {
                let lineEnd = position + UInt64(index) + 1
                guard !overCap, collected.count + index <= cap else { return (nil, lineEnd) }
                collected.append(block.prefix(index))
                return (collected, lineEnd)
            }
            if !overCap {
                if collected.count + block.count <= cap {
                    collected.append(block)
                } else {
                    collected = Data()
                    overCap = true
                }
            }
            position += UInt64(block.count)
        }
        return (nil, limit)
    }

    static func lastTaskStartedLineStart(_ descriptor: Int32, floor: UInt64, end: UInt64, chunk: Int,
                                         maxLineBytes: Int) throws -> UInt64? {
        let overlap = UInt64(taskStartedToken.count - 1)
        var blockEnd = end
        while blockEnd > floor {
            let blockStart = blockEnd - min(UInt64(chunk), blockEnd - floor)
            let readEnd = min(end, blockEnd + overlap)
            let block = try RolloutFileIO.readExactly(descriptor, offset: blockStart, count: Int(readEnd - blockStart))
            let hits = RolloutFileIO.occurrences(of: taskStartedToken, in: block)
                .filter { blockStart + UInt64($0) < blockEnd }
            for hit in hits.reversed() {
                let position = blockStart + UInt64(hit)
                guard let lineStart = try lineStart(descriptor, containing: position, floor: floor, maxLineBytes: maxLineBytes),
                      let lineEnd = try lineEnd(descriptor, from: position, end: end, maxLineBytes: maxLineBytes),
                      lineEnd - lineStart <= UInt64(maxLineBytes)
                else { continue }
                let line = try RolloutFileIO.readExactly(descriptor, offset: lineStart, count: Int(lineEnd - lineStart))
                if case .taskStarted? = CodexRolloutParser.parse(line: line) {
                    return lineStart
                }
            }
            blockEnd = blockStart
        }
        return nil
    }

    /// Offset just past the newline before `position` (or `floor`); nil past `maxLineBytes`.
    static func lineStart(_ descriptor: Int32, containing position: UInt64, floor: UInt64,
                          maxLineBytes: Int) throws -> UInt64? {
        var windowEnd = position
        while windowEnd > floor {
            if position - windowEnd > UInt64(maxLineBytes) { return nil }
            let windowStart = windowEnd - min(UInt64(lineSearchWindow), windowEnd - floor)
            let window = try RolloutFileIO.readExactly(descriptor, offset: windowStart, count: Int(windowEnd - windowStart))
            if let index = RolloutFileIO.lastIndex(of: 0x0A, in: window) {
                return windowStart + UInt64(index) + 1
            }
            windowEnd = windowStart
        }
        return floor
    }

    /// Offset of the newline that ends the line containing `position`; nil past `maxLineBytes`.
    static func lineEnd(_ descriptor: Int32, from position: UInt64, end: UInt64, maxLineBytes: Int) throws -> UInt64? {
        var windowStart = position
        while windowStart < end {
            if windowStart - position > UInt64(maxLineBytes) { return nil }
            let count = Int(min(UInt64(lineSearchWindow), end - windowStart))
            let window = try RolloutFileIO.readExactly(descriptor, offset: windowStart, count: count)
            if window.isEmpty { return nil }
            if let index = RolloutFileIO.firstIndex(of: 0x0A, in: window) {
                return windowStart + UInt64(index)
            }
            windowStart += UInt64(window.count)
        }
        return nil
    }

    static func completeLines(_ descriptor: Int32, from start: UInt64, to end: UInt64, chunk: Int,
                              maxLineBytes: Int) throws -> [Data] {
        var splitter = RolloutLineSplitter()
        var lines: [Data] = []
        var position = start
        while position < end {
            let block = try RolloutFileIO.readExactly(descriptor, offset: position,
                                                      count: Int(min(UInt64(chunk), end - position)))
            if block.isEmpty { break }
            splitter.feed(block, maxLineBytes: maxLineBytes, into: &lines)
            position += UInt64(block.count)
        }
        return lines
    }
}
