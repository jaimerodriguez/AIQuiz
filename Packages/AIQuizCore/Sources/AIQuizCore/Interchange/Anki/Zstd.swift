import Foundation
import libzstd

/// Zstandard decompression through Meta's libzstd (ADR-021): current Anki packages compress
/// the collection with it. Streaming, so frames without a stored content size work too.
public enum Zstd {
    public struct Failure: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { "The Anki collection couldn't be decompressed (\(message))." }
    }

    /// Output larger than this is refused (a damaged or hostile file).
    public static let maxOutput = 2 << 30

    public static func decompress(_ data: Data) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw Failure(message: "out of memory") }
        defer { ZSTD_freeDStream(stream) }
        let started = ZSTD_initDStream(stream)
        if ZSTD_isError(started) != 0 { throw Failure(message: String(cString: ZSTD_getErrorName(started))) }

        let chunk = ZSTD_DStreamOutSize()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        var finished = false
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            try buffer.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                // Keep going while input remains, or while the last call filled the buffer
                // (more output may be waiting).
                var filled = true
                while input.pos < input.size || filled {
                    var out = ZSTD_outBuffer(dst: target.baseAddress, size: chunk, pos: 0)
                    let result = ZSTD_decompressStream(stream, &out, &input)
                    if ZSTD_isError(result) != 0 { throw Failure(message: String(cString: ZSTD_getErrorName(result))) }
                    output.append(target.bindMemory(to: UInt8.self).baseAddress!, count: out.pos)
                    guard output.count <= maxOutput else { throw Failure(message: "the result is too large") }
                    finished = result == 0
                    filled = out.pos == chunk
                    if out.pos == 0 && input.pos == input.size { break }
                }
            }
        }
        guard finished else { throw Failure(message: "the data ends mid-frame") }
        return output
    }
}
