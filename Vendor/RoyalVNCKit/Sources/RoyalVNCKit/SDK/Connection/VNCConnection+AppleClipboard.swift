#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Apple's pasteboard messages are separate from standard RFB ServerCutText.
// This receive-only path never reads or writes the local system pasteboard.
extension VNCConnection {
    func subscribeToAppleClipboard() async throws {
        guard state.isAppleRemoteDesktop, serverClipboardTextHandler != nil else { return }
        try await connection.write(data: Data([0x15, 0, 0, 1, 0, 0, 0, 0]))
    }

    func receiveAppleClipboard() async throws {
        let flags = try await connection.read(length: 3)
        _ = try await connection.readUInt32() // Request echo.
        let expandedSize = Int(try await connection.readUInt32())
        let compressedSize = Int(try await connection.readUInt32())
        guard flags.count == 3, compressedSize <= 100 * 1024 * 1024 else {
            throw VNCError.protocol(.invalidData)
        }
        // History is text-only. Drain large image/file archives without allocating
        // their expanded contents or losing alignment with framebuffer messages.
        guard expandedSize <= 4 * 1024 * 1024, compressedSize <= 4 * 1024 * 1024 else {
            var remaining = compressedSize
            while remaining > 0 {
                let count = min(remaining, 64 * 1024)
                _ = try await connection.read(length: count)
                remaining -= count
            }
            return
        }
        let compressed = try await connection.read(length: compressedSize)
        guard serverClipboardTextHandler != nil else { return }
        if flags[1] & 1 != 0 {
            // A promise announces new flavors; ask for the actual contents.
            try await connection.write(data: Data([0x0b, 0, 0, 0, 0, 0, 0, 1]))
            return
        }
        guard expandedSize > 0 else { return }
        do {
            let archive = try ZlibStream().decompressedData(compressedData: compressed,
                                                          uncompressedSize: UInt(expandedSize))
            if let text = try AppleClipboardArchive.text(in: archive) {
                serverClipboardTextHandler?(self, text)
            }
        } catch {
            // The full packet has been consumed; a bad clipboard must not end
            // an otherwise healthy desktop stream. Never log clipboard contents.
            logger.logDebug("Ignoring malformed Apple clipboard archive")
        }
    }
}

enum AppleClipboardArchive {
    static func text(in data: Data) throws -> String? {
        var cursor = Cursor(bytes: Array(data))
        var utf16: String?
        var utf8: String?
        while cursor.remaining > 0 {
            let flavors = try cursor.number()
            guard flavors <= 1024 else { throw VNCError.protocol(.invalidData) }
            for _ in 0..<flavors {
                let type = String(decoding: try cursor.field(), as: UTF8.self)
                _ = try cursor.number() // Reserved flavor attributes.
                let tags = try cursor.number()
                guard tags <= 256 else { throw VNCError.protocol(.invalidData) }
                for _ in 0..<tags {
                    _ = try cursor.field()
                    _ = try cursor.field()
                }
                let value = try cursor.field()
                guard !value.isEmpty, value.count <= 64 * 1024 else { continue }
                if type == "public.utf8-plain-text", utf8 == nil {
                    utf8 = String(bytes: value, encoding: .utf8)
                } else if type == "public.utf16-plain-text", utf16 == nil, value.count.isMultiple(of: 2) {
                    utf16 = String(data: Data(value), encoding: .utf16BigEndian)
                }
            }
        }
        return utf8 ?? utf16
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }

        mutating func number() throws -> Int {
            guard remaining >= 4 else { throw VNCError.protocol(.invalidData) }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }

        mutating func field() throws -> ArraySlice<UInt8> {
            let count = try number()
            guard count <= remaining else { throw VNCError.protocol(.invalidData) }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }
    }
}
