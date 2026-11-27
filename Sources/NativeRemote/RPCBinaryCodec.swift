import Foundation

/// ZCode's VS Code-style binary RPC codec.
///
/// A value is a one-byte tag plus a 7-bit little-endian varint length/value.
/// The relay carries these bytes Base64-encoded inside `rpc-frame` payloads.
nonisolated enum RPCValue: Sendable, Equatable {
    case undefined
    case string(String)
    case data(Data)
    case array([RPCValue])
    case object(String)
    case int(Int)

    fileprivate enum Tag: UInt8 {
        case undefined = 0
        case string = 1
        case buffer = 2
        case vsBuffer = 3
        case array = 4
        case object = 5
        case int = 6
    }

    var jsonValue: Any {
        switch self {
        case .undefined: NSNull()
        case .string(let value): value
        case .data(let value): value.base64EncodedString()
        case .array(let values): values.map(\.jsonValue)
        case .object(let json): (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? json
        case .int(let value): value
        }
    }

    static func decode(_ bytes: Data) throws -> RPCValue {
        var reader = BinaryReader(data: bytes)
        let value = try reader.readValue()
        return value
    }

    static func encode(_ value: RPCValue) -> Data {
        var writer = BinaryWriter()
        writer.write(value)
        return writer.data
    }
}

nonisolated struct RPCMessage: Sendable, Equatable {
    let type: Int
    let id: Int
    let ack: Int
    let channel: String
    let payload: RPCValue

    /// Incoming frames put the response type in the first value and the data
    /// in the second; outgoing calls put channel in the first and
    /// `[method, arguments]` in the second.
    static func decode(_ bytes: Data) throws -> RPCMessage {
        var reader = BinaryReader(data: bytes)
        let header = try reader.readValue()
        let body = try reader.readValue()
        guard case .array(let fields) = header, fields.count >= 4 else {
            throw RPCError.malformedHeader
        }
        func int(_ value: RPCValue) throws -> Int {
            guard case .int(let number) = value else { throw RPCError.malformedHeader }
            return number
        }
        func text(_ value: RPCValue) throws -> String {
            guard case .string(let string) = value else { throw RPCError.malformedHeader }
            return string
        }
        return RPCMessage(
            type: try int(fields[0]),
            id: try int(fields[1]),
            ack: try int(fields[2]),
            channel: try text(fields[3]),
            payload: body
        )
    }

    static func request(id: Int, channel: String, method: String, arguments: RPCValue) -> Data {
        var writer = BinaryWriter()
        writer.write(.array([.int(100), .int(id), .int(0), .string(channel)]))
        writer.write(.array([.string(method), arguments]))
        return writer.data
    }
}

nonisolated enum RPCError: Error {
    case malformedHeader
    case truncated
    case unsupportedTag(UInt8)
}

nonisolated private struct BinaryReader {
    let data: Data
    private var offset = 0

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw RPCError.truncated }
        let byte = data[data.startIndex + offset]
        offset += 1
        return byte
    }

    mutating func readVarint() throws -> Int {
        var result = 0
        var shift = 0
        while true {
            let byte = try readByte()
            result |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readBytes() throws -> Data {
        let length = try readVarint()
        guard offset + length <= data.count else { throw RPCError.truncated }
        let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
        offset += length
        return chunk
    }

    mutating func readValue() throws -> RPCValue {
        let tag = try readByte()
        switch RPCValue.Tag(rawValue: tag) {
        case .undefined: return .undefined
        case .string:
            return .string(String(decoding: try readBytes(), as: UTF8.self))
        case .buffer, .vsBuffer:
            return .data(try readBytes())
        case .array:
            let count = try readVarint()
            var values: [RPCValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try readValue()) }
            return .array(values)
        case .object:
            return .object(String(decoding: try readBytes(), as: UTF8.self))
        case .int:
            return .int(try readVarint())
        case nil:
            throw RPCError.unsupportedTag(tag)
        }
    }
}

nonisolated private struct BinaryWriter {
    var data = Data()

    mutating func writeVarint(_ value: Int) {
        var remaining = value
        while true {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
            if remaining == 0 { return }
        }
    }

    mutating func write(_ value: RPCValue) {
        switch value {
        case .undefined:
            data.append(RPCValue.Tag.undefined.rawValue)
        case .string(let string):
            data.append(RPCValue.Tag.string.rawValue)
            let bytes = Data(string.utf8)
            writeVarint(bytes.count)
            data.append(bytes)
        case .data(let bytes):
            data.append(RPCValue.Tag.vsBuffer.rawValue)
            writeVarint(bytes.count)
            data.append(bytes)
        case .array(let values):
            data.append(RPCValue.Tag.array.rawValue)
            writeVarint(values.count)
            for value in values { write(value) }
        case .object(let json):
            data.append(RPCValue.Tag.object.rawValue)
            let bytes = Data(json.utf8)
            writeVarint(bytes.count)
            data.append(bytes)
        case .int(let number):
            data.append(RPCValue.Tag.int.rawValue)
            writeVarint(number)
        }
    }
}

nonisolated enum CRC32 {
    static func hex(_ data: Data) -> String {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0)
            }
        }
        return String(format: "%08x", crc ^ 0xFFFFFFFF)
    }
}
