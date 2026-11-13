import Foundation

@main
struct UniversalIRSmoke {
    static func main() {
        let sample = """
        Filetype: IR library file
        Version: 1
        #
        name: Power
        type: parsed
        protocol: NEC
        address: 12 00 00 00
        command: 34 00 00 00
        #
        name: Power
        type: raw
        frequency: 38000
        duty_cycle: 0.330000
        data: 9000 4500
        """
        let entries = UniversalIRParser.parse(Data(sample.utf8))
        precondition(entries?.count == 2)
        precondition(entries?[0].name == "Power" && entries?[1].name == "Power")
        precondition(entries?[0].detail.contains("NEC") == true)
        precondition(entries?[1].detail == "RAW · 38000 Hz")
        precondition(entries?[0].signalFile.hasPrefix("Filetype: IR signals file\nVersion: 1") == true)
        precondition(entries?[1].signalFile.contains("data: 9000 4500") == true)
        precondition(UniversalIRParser.parse(Data("Filetype: IR signals file".utf8)) == nil)
        print("Universal IR parser smoke tests: OK")
    }
}
