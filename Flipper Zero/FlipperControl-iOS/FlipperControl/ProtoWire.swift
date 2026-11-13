import Foundation

// Subconjunto codificador/decodificador wire-format de protobuf, sin dependencias.
// Campos basados en https://github.com/flipperdevices/flipperzero-protobuf (rama dev).
enum ProtoWire {
    struct Field {
        let number: Int
        let wire: Int
        let integer: UInt64?
        let bytes: Data?
    }
    static func varint(_ n: UInt64) -> Data {
        var n = n
        var data = Data()
        repeat {
            let b = UInt8(n & 0x7F)
            n >>= 7
            data.append(n == 0 ? b : (b | 0x80))
        } while n != 0
        return data
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data {
        var data = varint(UInt64(field << 3))
        data.append(varint(value))
        return data
    }
    static func bytes(_ field: Int, _ value: Data) -> Data {
        var data = varint(UInt64((field << 3) | 2))
        data.append(varint(UInt64(value.count)))
        data.append(value)
        return data
    }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    static func message(_ field: Int, _ value: Data) -> Data { bytes(field, value) }
    static func readVarint(_ data: Data, at index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard index < data.count else { return nil }
            let byte = data[index]
            index += 1
            if shift == 63 && byte > 1 { return nil }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
    static func fields(_ data: Data) -> [Field] {
        var index = 0
        var result: [Field] = []
        while index < data.count {
            guard let key = readVarint(data, at: &index) else { break }
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            guard number > 0 else { break }
            switch wire {
            case 0:
                guard let value = readVarint(data, at: &index) else { return result }
                result.append(Field(number: number, wire: wire, integer: value, bytes: nil))
            case 2:
                guard let count = readVarint(data, at: &index), count <= UInt64(data.count-index) else { return result }
                let length = Int(count)
                result.append(Field(number: number, wire: wire, integer: nil, bytes: data.subdata(in: index..<(index+length))))
                index += length
            case 1:
                guard index + 8 <= data.count else { return result }
                index += 8
            case 5:
                guard index + 4 <= data.count else { return result }
                index += 4
            default: return result
            }
        }
        return result
    }
    static func data(_ data: Data, field: Int) -> Data? { fields(data).first { $0.number == field }?.bytes }
    static func number(_ data: Data, field: Int) -> UInt64? { fields(data).first { $0.number == field }?.integer }
    static func text(_ data: Data, field: Int) -> String? {
        guard let v = self.data(data, field: field) else { return nil }
        return String(data: v, encoding: .utf8)
    }
    static func framed(_ message: Data) -> Data { varint(UInt64(message.count)) + message }
    static func bigEndianUInt32(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

struct FlipperFile: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int
    var icon: String { isDirectory ? "folder.fill" : "doc.fill" }
}

enum FlipperError: LocalizedError {
    case notConnected
    case timeout
    case response(Int)
    case invalidResponse
    case transferTooLarge
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Flipper no conectado"
        case .timeout: return "El Flipper no respondió. Vuelve a intentarlo."
        case .response(17): return "Flipper ocupado: cierra la aplicación abierta en el dispositivo y vuelve a intentarlo (RPC 17)."
        case .response(let code): return "El Flipper devolvió el error RPC \(code)"
        case .invalidResponse: return "Respuesta RPC inesperada"
        case .transferTooLarge: return "Este archivo necesita transferencia por fragmentos"
        case .unavailable(let info): return info
        }
    }
}
