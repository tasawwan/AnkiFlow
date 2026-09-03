import Foundation

/// Writes a ZIP archive with stored (uncompressed) entries.
///
/// An .apkg is a plain zip. Entries are stored rather than deflated because the
/// media is already compressed and the collection database is small -- storing
/// removes an entire class of compression bug from the one file format that
/// absolutely has to be readable by Anki.
struct ZipWriter {
    private struct Entry {
        let name: String
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []

    mutating func add(name: String, data: Data) {
        let offset = UInt32(output.count)
        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        let nameBytes = Array(name.utf8)

        // Local file header
        write32(0x04034b50)
        write16(20)                            // version needed
        write16(0)                             // flags
        write16(0)                             // method: stored
        write16(0)                             // mod time
        write16(0x21)                          // mod date (1980-01-01)
        write32(crc)
        write32(size)                          // compressed size
        write32(size)                          // uncompressed size
        write16(UInt16(nameBytes.count))
        write16(0)                             // extra length
        output.append(contentsOf: nameBytes)
        output.append(data)

        entries.append(Entry(name: name, crc: crc, size: size, offset: offset))
    }

    mutating func finish() -> Data {
        let centralDirectoryOffset = UInt32(output.count)

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            write32(0x02014b50)
            write16(20)                        // version made by
            write16(20)                        // version needed
            write16(0)                         // flags
            write16(0)                         // method: stored
            write16(0)                         // mod time
            write16(0x21)                      // mod date
            write32(entry.crc)
            write32(entry.size)
            write32(entry.size)
            write16(UInt16(nameBytes.count))
            write16(0)                         // extra length
            write16(0)                         // comment length
            write16(0)                         // disk number start
            write16(0)                         // internal attributes
            write32(0)                         // external attributes
            write32(entry.offset)
            output.append(contentsOf: nameBytes)
        }

        let centralDirectorySize = UInt32(output.count) - centralDirectoryOffset

        // End of central directory
        write32(0x06054b50)
        write16(0)                             // this disk
        write16(0)                             // disk with central directory
        write16(UInt16(entries.count))
        write16(UInt16(entries.count))
        write32(centralDirectorySize)
        write32(centralDirectoryOffset)
        write16(0)                             // comment length

        return output
    }

    private mutating func write16(_ value: UInt16) {
        output.append(UInt8(value & 0xFF))
        output.append(UInt8((value >> 8) & 0xFF))
    }

    private mutating func write32(_ value: UInt32) {
        output.append(UInt8(value & 0xFF))
        output.append(UInt8((value >> 8) & 0xFF))
        output.append(UInt8((value >> 16) & 0xFF))
        output.append(UInt8((value >> 24) & 0xFF))
    }
}

enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
