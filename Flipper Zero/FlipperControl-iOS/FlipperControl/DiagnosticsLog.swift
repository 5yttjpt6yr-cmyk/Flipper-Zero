import Foundation

@MainActor
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    let fileURL: URL
    private let formatter = ISO8601DateFormatter()
    private let maximumBytes = 512_000

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("FlipperControl-diagnostico.log")
        record("Inicio de sesión. App \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func record(_ message: String) {
        let clean = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let line = "\(formatter.string(from: Date()))  \(clean)\n"
        guard let bytes = line.data(using: .utf8) else { return }
        do {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size > maximumBytes {
                try Data("Registro anterior archivado por límite de tamaño.\n".utf8).write(to: fileURL, options: .atomic)
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            // El diagnóstico nunca debe impedir el uso de la aplicación.
        }
    }
}
