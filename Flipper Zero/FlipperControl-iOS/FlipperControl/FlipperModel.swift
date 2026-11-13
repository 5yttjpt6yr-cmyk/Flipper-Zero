import Foundation
import SwiftUI
import UIKit

struct FavoriteSignal: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var kind: String
    var path: String
    var index: Int = 0
    var icon: String = "bolt.fill"
    var folder: String? = nil
}

@MainActor
final class FlipperModel: ObservableObject {
    let ble = FlipperBLE()
    @Published var favorites: [FavoriteSignal] = []
    @Published var favoriteFolders: [String] = ["General"]
    @Published var remoteFiles: [FlipperFile] = []
    @Published var currentPath = "/ext"
    @Published var busy = false
    @Published var notice: String?
    @Published var screen: UIImage?
    @Published var streaming = false
    @Published var selectedRemote: FlipperFile?
    @Published var clipboard: (path: String, isRemote: Bool)?
    private var activeApp: String?
    private var activeAppSession = -1
    private var loadedSignalPath: String?
    private var irButtonCache: [String: [FavoriteSignal]] = [:]
    private var universalIRCache: [String: [UniversalIREntry]] = [:]
    private var preparedUniversalPaths: Set<String> = []
    private var preparedUniversalSession = -1
    private var universalFolderReady = false
    private var pendingScreenFrame: Data?
    private var screenRenderScheduled = false
    private var lastScreenRender = Date.distantPast
    private let favoritesKey = "k41k35_favorites_v1"
    private let favoriteFoldersKey = "k41k35_favorite_folders_v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let list = try? JSONDecoder().decode([FavoriteSignal].self, from: data) { favorites = list }
        let savedFolders = UserDefaults.standard.stringArray(forKey: favoriteFoldersKey) ?? []
        favoriteFolders = Array(Set(["General"] + savedFolders + favorites.compactMap(\.folder))).sorted()
        ble.unsolicited = { [weak self] packet in self?.processUnsolicited(packet) }
    }
    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(data, forKey: favoritesKey) }
    }
    func createFavoriteFolder(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40 else { return }
        if !favoriteFolders.contains(clean) {
            favoriteFolders.append(clean)
            favoriteFolders.sort()
            UserDefaults.standard.set(favoriteFolders, forKey: favoriteFoldersKey)
        }
    }
    func addFavorite(_ signal: FavoriteSignal, to folder: String = "General") {
        createFavoriteFolder(folder)
        var item = signal
        item.folder = folder
        favorites.append(item)
        saveFavorites()
    }
    func moveFavorite(_ signal: FavoriteSignal, to folder: String) {
        createFavoriteFolder(folder)
        guard let index = favorites.firstIndex(where: { $0.id == signal.id }) else { return }
        favorites[index].folder = folder
        saveFavorites()
    }
    func deleteFavorites(at offsets: IndexSet) { favorites.remove(atOffsets: offsets); saveFavorites() }
    func message(_ text: String) { notice = text }
    func perform(_ task: @escaping () async throws -> Void) {
        guard !busy else {
            DiagnosticsLog.shared.record("Operación omitida: otra operación sigue activa")
            notice = "Espera a que termine la operación anterior"
            return
        }
        busy = true
        Task {
            do { try await task() }
            catch {
                DiagnosticsLog.shared.record("Operación falló: \(error.localizedDescription)")
                notice = error.localizedDescription
            }
            busy = false
        }
    }
    func refresh(path: String? = nil) async throws {
        guard ble.connected else { throw FlipperError.notConnected }
        let path = path ?? currentPath
        let result = try await ble.rpc(7, payload: ProtoWire.string(1, path))
        guard result.contains(where: { ProtoWire.data($0, field: 8) != nil }) else { throw FlipperError.invalidResponse }
        var items: [FlipperFile] = []
        for packet in result {
            guard let body = ProtoWire.data(packet, field: 8) else { continue }
            for record in ProtoWire.fields(body) where record.number == 1 {
                guard let fileData = record.bytes,
                      let name = ProtoWire.text(fileData, field: 2) else { continue }
                let dir = ProtoWire.number(fileData, field: 1) == 1
                let filePath = (path == "/" ? "" : path) + "/" + name
                items.append(FlipperFile(name: name, path: filePath, isDirectory: dir, size: Int(ProtoWire.number(fileData, field: 3) ?? 0)))
            }
        }
        remoteFiles = items.sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
        currentPath = path
    }
    func parentDirectory() async throws {
        let parts = currentPath.split(separator: "/")
        try await refresh(path: parts.count < 2 ? "/" : "/" + parts.dropLast().joined(separator: "/"))
    }
    func read(_ path: String) async throws -> Data {
        let packets = try await ble.rpc(9, payload: ProtoWire.string(1, path))
        var result = Data()
        for packet in packets {
            guard let response = ProtoWire.data(packet, field: 10),
                  let file = ProtoWire.data(response, field: 1) else { throw FlipperError.invalidResponse }
            let chunk = ProtoWire.data(file, field: 4) ?? Data()
            guard result.count <= 32_000_000 - chunk.count else { throw FlipperError.transferTooLarge }
            result.append(chunk)
        }
        return result
    }
    func write(_ data: Data, to path: String) async throws {
        guard data.count <= 32_000_000 else { throw FlipperError.transferTooLarge }
        guard !data.isEmpty else {
            // Un archivo vacío también se envía como solicitud de escritura.
            let file = ProtoWire.bytes(4, Data())
            _ = try await ble.rpc(11, payload: ProtoWire.string(1, path) + ProtoWire.message(2, file))
            return
        }
        var requests: [Data] = []
        for offset in stride(from: 0, to: data.count, by: 512) {
            let end = min(data.count, offset + 512)
            let chunk = data.subdata(in: offset..<end)
            let file = ProtoWire.bytes(4, chunk)
            requests.append(ProtoWire.string(1, path) + ProtoWire.message(2, file))
        }
        _ = try await ble.rpcStream(11, payloads: requests)
    }
    func mkdir(_ name: String) async throws {
        let path = currentPath + "/" + name
        _ = try await ble.rpc(13, payload: ProtoWire.string(1, path))
        try await refresh()
    }
    func remove(_ file: FlipperFile) async throws {
        var payload = ProtoWire.string(1, file.path)
        if file.isDirectory { payload.append(ProtoWire.integer(2, 1)) }
        _ = try await ble.rpc(12, payload: payload)
        try await refresh()
    }
    func rename(_ file: FlipperFile, as newName: String) async throws {
        let destination = (file.path as NSString).deletingLastPathComponent + "/" + newName
        _ = try await ble.rpc(30, payload: ProtoWire.string(1, file.path) + ProtoWire.string(2, destination))
        try await refresh()
    }
    func importLocal(_ url: URL, folder: String? = nil) async throws {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let destination = (folder ?? currentPath) + "/" + url.lastPathComponent
        try await write(data, to: destination)
        try await refresh()
        notice = "Archivo copiado: \(url.lastPathComponent)"
    }
    func exportRemote(_ file: FlipperFile) async throws -> URL {
        guard !file.isDirectory else { throw FlipperError.unavailable("Selecciona un archivo, no una carpeta") }
        let data = try await read(file.path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        try data.write(to: url, options: .atomic)
        return url
    }
    func listSignals(in folder: String, kind: String) async throws -> [FavoriteSignal] {
        var signals: [FavoriteSignal] = []
        let suffix = kind == "IR" ? ".ir" : ".sub"
        DiagnosticsLog.shared.record("Señales \(kind): explorando \(folder)")
        let result = try await ble.rpc(7, payload: ProtoWire.string(1, folder))
        for packet in result {
            guard let body = ProtoWire.data(packet, field: 8) else { continue }
            for entry in ProtoWire.fields(body) where entry.number == 1 {
                guard let file = entry.bytes,
                      let name = ProtoWire.text(file, field: 2) else { continue }
                let filePath = folder + "/" + name
                if ProtoWire.number(file, field: 1) == 1 {
                    // assets contiene diccionarios universales, no mandos cargables por RPC.
                    if kind == "IR" && folder == "/ext/infrared" && name.lowercased() == "assets" { continue }
                    signals.append(FavoriteSignal(title: name, kind: "Folder", path: filePath, index: -1, icon: "folder.fill"))
                } else if name.lowercased().hasSuffix(suffix) {
                    signals.append(FavoriteSignal(title: String(name.dropLast(suffix.count)), kind: kind, path: filePath, index: kind == "IR" ? -1 : 0, icon: kind == "IR" ? "doc.text" : "antenna.radiowaves.left.and.right"))
                }
            }
        }
        DiagnosticsLog.shared.record("Señales \(kind): \(signals.count) elementos en \(folder)")
        return signals.sorted { $0.kind == $1.kind ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.kind == "Folder" }
    }
    func irButtons(in signal: FavoriteSignal) async throws -> [FavoriteSignal] {
        guard signal.kind == "IR", signal.index == -1 else { throw FlipperError.invalidResponse }
        if let cached = irButtonCache[signal.path] { return cached }
        DiagnosticsLog.shared.record("IR leyendo botones de \(signal.path)")
        let raw = try await read(signal.path)
        guard let content = String(data: raw, encoding: .utf8) else { throw FlipperError.invalidResponse }
        let buttons = content.split(separator: "\n").compactMap { line -> String? in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.lowercased().hasPrefix("name:") else { return nil }
            return String(clean.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        DiagnosticsLog.shared.record("IR \(signal.path): \(buttons.count) botones en \(raw.count) bytes")
        let signals = buttons.enumerated().map { index, name in
            FavoriteSignal(title: "\(signal.title) · \(name)", kind: "IR", path: signal.path, index: index, icon: "power")
        }
        irButtonCache[signal.path] = signals
        return signals
    }
    func universalEntries(in signal: FavoriteSignal) async throws -> [UniversalIREntry] {
        guard signal.path.hasPrefix("/ext/infrared/assets/"), signal.path.lowercased().hasSuffix(".ir") else {
            throw FlipperError.invalidResponse
        }
        if let cached = universalIRCache[signal.path] { return cached }
        DiagnosticsLog.shared.record("IR universal leyendo \(signal.path)")
        let raw = try await read(signal.path)
        guard let entries = UniversalIRParser.parse(raw) else {
            throw FlipperError.unavailable("El archivo no es una biblioteca IR universal compatible")
        }
        universalIRCache[signal.path] = entries
        DiagnosticsLog.shared.record("IR universal \(signal.path): \(entries.count) códigos en \(raw.count) bytes")
        return entries
    }
    private func universalSignal(_ entry: UniversalIREntry, library: FavoriteSignal) async throws -> FavoriteSignal {
        guard ble.connected, library.path.hasPrefix("/ext/infrared/assets/"),
              library.path.lowercased().hasSuffix(".ir") else { throw FlipperError.notConnected }
        if preparedUniversalSession != ble.sessionID {
            preparedUniversalSession = ble.sessionID
            preparedUniversalPaths.removeAll()
            universalFolderReady = false
        }
        if !universalFolderReady {
            let root = try await listSignals(in: "/ext/infrared", kind: "IR")
            if !root.contains(where: { $0.kind == "Folder" && $0.path == "/ext/infrared/FlipperControl" }) {
                _ = try await ble.rpc(13, payload: ProtoWire.string(1, "/ext/infrared/FlipperControl"))
            }
            universalFolderReady = true
        }
        let libraryName = String(library.title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.prefix(24))
        let path = "/ext/infrared/FlipperControl/FC_\(libraryName)_\(entry.id).ir"
        if !preparedUniversalPaths.contains(path) {
            DiagnosticsLog.shared.record("IR universal preparando \(path)")
            try await write(Data(entry.signalFile.utf8), to: path)
            preparedUniversalPaths.insert(path)
        }
        return FavoriteSignal(title: "\(library.title) · \(entry.name) #\(entry.id + 1)", kind: "IR", path: path, index: 0, icon: "power")
    }
    func emulateUniversal(_ entry: UniversalIREntry, library: FavoriteSignal) async throws {
        let signal = try await universalSignal(entry, library: library)
        try await transmit(signal)
    }
    func saveUniversal(_ entry: UniversalIREntry, library: FavoriteSignal, folder: String) async throws {
        let signal = try await universalSignal(entry, library: library)
        if !favorites.contains(where: { $0.kind == "IR" && $0.path == signal.path && ($0.folder ?? "General") == folder }) {
            addFavorite(signal, to: folder)
        }
        notice = "Guardado en \(folder): \(signal.title)"
    }
    func transmit(_ signal: FavoriteSignal) async throws {
        guard ble.connected else { throw FlipperError.notConnected }
        let app = signal.kind == "IR" ? "Infrared" : "Sub-GHz"
        guard signal.index >= 0, signal.path.hasPrefix("/ext/"), signal.path.lowercased().hasSuffix(signal.kind == "IR" ? ".ir" : ".sub") else {
            throw FlipperError.unavailable("Ruta de señal no válida")
        }
        guard !signal.path.lowercased().contains("/assets/") else {
            throw FlipperError.unavailable("Los diccionarios IR universales no se emiten como mandos guardados")
        }
        if activeAppSession != ble.sessionID { activeApp = nil; loadedSignalPath = nil }
        if activeApp != app || loadedSignalPath != signal.path {
            if activeApp != nil {
                _ = try? await ble.rpc(47)
                activeApp = nil
                loadedSignalPath = nil
            }
            let start = ProtoWire.string(1, app) + ProtoWire.string(2, "RPC")
            _ = try await ble.rpc(16, payload: start)
            activeApp = app
            activeAppSession = ble.sessionID
        }
        do {
            if loadedSignalPath != signal.path {
                _ = try await ble.rpc(48, payload: ProtoWire.string(1, signal.path))
                loadedSignalPath = signal.path
            }
            _ = try await ble.rpc(75, payload: ProtoWire.integer(2, UInt64(signal.index)))
            notice = "Emisión confirmada por el Flipper"
        } catch {
            var reportedError: Error = error
            if case FlipperError.response(22) = error {
                let detail = try? await ble.rpc(63)
                if let detail = detail?.first.flatMap({ ProtoWire.data($0, field: 64) }),
                   let message = ProtoWire.text(detail, field: 2) {
                    DiagnosticsLog.shared.record("Emisión rechazada: \(message)")
                    reportedError = FlipperError.unavailable(message)
                }
            }
            _ = try? await ble.rpc(47)
            activeApp = nil
            loadedSignalPath = nil
            throw reportedError
        }
    }
    func startSubGHz() async throws {
        DiagnosticsLog.shared.record("Read RAW: solicitando abrir Sub-GHz; captura directa no implementada")
        if activeAppSession != ble.sessionID { activeApp = nil; loadedSignalPath = nil }
        if activeApp != "Sub-GHz" {
            if activeApp != nil { _ = try? await ble.rpc(47); activeApp = nil; loadedSignalPath = nil }
            _ = try await ble.rpc(16, payload: ProtoWire.string(1, "Sub-GHz") + ProtoWire.string(2, "RPC"))
            activeApp = "Sub-GHz"
            activeAppSession = ble.sessionID
        }
        notice = "Abre Read RAW desde la pantalla remota; inicio directo pendiente de validación DEV"
    }
    func startScreen() async throws {
        DiagnosticsLog.shared.record("Remoto: iniciar pantalla")
        _ = try await ble.rpc(20)
        streaming = true
    }
    func stopScreen() async throws {
        DiagnosticsLog.shared.record("Remoto: detener pantalla")
        _ = try await ble.rpc(21)
        streaming = false
    }
    func press(_ key: Int) async throws {
        DiagnosticsLog.shared.record("Remoto: tecla \(key) pulsar, corto y soltar")
        let press = ProtoWire.integer(1, UInt64(key)) + ProtoWire.integer(2, 0)
        let short = ProtoWire.integer(1, UInt64(key)) + ProtoWire.integer(2, 2)
        let release = ProtoWire.integer(1, UInt64(key)) + ProtoWire.integer(2, 1)
        try await ble.rpcSequence([(23, press), (23, short), (23, release)])
    }
    private func processUnsolicited(_ packet: Data) {
        guard let frame = ProtoWire.data(packet, field: 22) else { return }
        guard let bytes = ProtoWire.data(frame, field: 1), bytes.count >= 1024 else {
            DiagnosticsLog.shared.record("Remoto: fotograma inválido")
            return
        }
        pendingScreenFrame = bytes
        guard !screenRenderScheduled else { return }
        screenRenderScheduled = true
        Task { @MainActor in
            let wait = max(0, 1.0 / 15.0 - Date().timeIntervalSince(lastScreenRender))
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let latest = pendingScreenFrame, streaming else {
                pendingScreenFrame = nil
                screenRenderScheduled = false
                return
            }
            pendingScreenFrame = nil
            screenRenderScheduled = false
            lastScreenRender = Date()
            renderScreen(latest)
        }
    }
    private func renderScreen(_ bytes: Data) {
        // Monochrome 128 x 64, 1 bit/pixel. El orden de bits se comprobará con hardware real.
        var pixels = [UInt8](repeating: 0, count: 128 * 64)
        for y in 0..<64 {
            for x in 0..<128 {
                // u8g2 entrega páginas verticales de 8 píxeles por columna.
                let offset = (y / 8) * 128 + x
                let set = (bytes[offset] & UInt8(1 << (y % 8))) != 0
                pixels[y * 128 + x] = set ? 18 : 242
            }
        }
        let providerData = Data(pixels)
        guard let provider = CGDataProvider(data: providerData as CFData),
              let cg = CGImage(width: 128, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        screen = UIImage(cgImage: cg)
    }
}
