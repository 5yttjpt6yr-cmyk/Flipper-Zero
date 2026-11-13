import Foundation
@main
struct Smoke {
    static func main() {
        let payload = ProtoWire.integer(1, 142) + ProtoWire.string(2, "Unleashed DEV") + ProtoWire.message(7, ProtoWire.string(1, "/ext"))
        assert(ProtoWire.number(payload, field: 1) == 142)
        assert(ProtoWire.text(payload, field: 2) == "Unleashed DEV")
        assert(ProtoWire.text(ProtoWire.data(payload, field: 7)!, field: 1) == "/ext")
        let framed = ProtoWire.framed(payload)
        var offset = 0
        assert(ProtoWire.readVarint(framed, at: &offset) == UInt64(payload.count))
        assert(framed.subdata(in: offset..<framed.count) == payload)
        let long = ProtoWire.bytes(4, Data(repeating: 0xAB, count: 900))
        assert(ProtoWire.data(long, field: 4)?.count == 900)
        assert(ProtoWire.bigEndianUInt32(Data([0, 0, 1, 230])) == 486)
        assert(ProtoWire.bigEndianUInt32(Data([0, 1])) == nil)
        var brokenOffset = 0
        assert(ProtoWire.readVarint(Data(repeating: 0x80, count: 11), at: &brokenOffset) == nil)
        print("ProtoWire smoke tests: OK")
    }
}
