import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum Palette {
    static let background = Color(red: 8/255, green: 9/255, blue: 11/255)
    static let surface = Color(red: 23/255, green: 24/255, blue: 27/255)
    static let elevated = Color(red: 34/255, green: 35/255, blue: 38/255)
    static let gold = Color(red: 201/255, green: 163/255, blue: 72/255)
    static let pale = Color(red: 241/255, green: 231/255, blue: 209/255)
    static let muted = Color(red: 158/255, green: 154/255, blue: 145/255)
}

@main
struct FlipperControlApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = FlipperModel()
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .tint(Palette.gold)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.ble.resumeKnownConnection() }
                    if phase == .background && model.streaming {
                        Task { try? await model.stopScreen() }
                    }
                }
        }
    }
}

private struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Palette.gold.opacity(0.19), lineWidth: 1))
    }
}
private struct ModuleTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Palette.gold)
                Spacer(minLength: 2)
                Text(title).font(.headline).foregroundStyle(Palette.pale)
                Text(subtitle).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 120)
        }
    }
}
private struct GoldButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline)
                .foregroundStyle(Palette.background).frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Palette.gold, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
}
private struct RootView: View {
    @ObservedObject var model: FlipperModel
    @State private var tab = 0
    @State private var showConnection = false
    var body: some View {
        TabView(selection: $tab) {
            HomeView(model: model, tab: $tab).tabItem { Label("Inicio", systemImage: "house.fill") }.tag(0)
            SignalsView(model: model).tabItem { Label("Mandos", systemImage: "antenna.radiowaves.left.and.right") }.tag(1)
            FilesView(model: model).tabItem { Label("Archivos", systemImage: "folder.fill") }.tag(2)
            RemoteView(model: model).tabItem { Label("Remoto", systemImage: "gamecontroller.fill") }.tag(3)
        }
        .toolbarBackground(Palette.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $showConnection) { ConnectionView(ble: model.ble) }
        .overlay(alignment: .top) {
            if let message = model.notice {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Palette.gold)
                    Text(message).font(.subheadline).lineLimit(3)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                }
                .padding().background(Palette.elevated, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12).padding(.top, 4)
            }
        }
        .environment(\.openConnection, { showConnection = true })
    }
}
private struct ConnectionActionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
private extension EnvironmentValues {
    var openConnection: () -> Void {
        get { self[ConnectionActionKey.self] }
        set { self[ConnectionActionKey.self] = newValue }
    }
}
private struct DeviceHeader: View {
    @ObservedObject var ble: FlipperBLE
    @Environment(\.openConnection) private var openConnection
    var body: some View {
        Button(action: openConnection) {
            HStack(spacing: 13) {
                Image(systemName: "cpu.fill")
                    .font(.title2).foregroundStyle(Palette.gold)
                    .frame(width: 45, height: 45)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(ble.deviceName).font(.headline).foregroundStyle(Palette.pale)
                    Text(ble.state).font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                if let battery = ble.battery {
                    Text("\(battery)%").font(.caption).foregroundStyle(Palette.muted)
                }
                Image(systemName: ble.connected ? "bluetooth" : "bluetooth.slash")
                    .font(.title3).foregroundStyle(ble.connected ? .green : Palette.muted)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }
        }.buttonStyle(.plain)
    }
}
private struct HomeView: View {
    @ObservedObject var model: FlipperModel
    @Binding var tab: Int
    @AppStorage("homeModules") private var moduleString = "Mandos,Archivos,Remoto,FAPs"
    @State private var editing = false
    private var modules: [String] { moduleString.split(separator: ",").map(String.init).filter { $0 != "Temas" && $0 != "IA" } }
    private let metadata: [String: (String,String)] = [
        "Mandos": ("hifispeaker.and.homepod", "IR y Sub-GHz"),
        "Archivos": ("folder.fill", "Copiar y pegar"),
        "Remoto": ("gamecontroller.fill", "Pantalla del Flipper"),
        "FAPs": ("square.stack.3d.up.fill", "Instalar aplicaciones"),
    ]
    @State private var extra: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("FLIPPER").font(.system(size: 27, weight: .heavy, design: .rounded)).tracking(2)
                            Text("CONTROL · UNLEASHED DEV").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.gold)
                        }
                        Spacer()
                        Button { editing = true } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
                    }
                    Panel { DeviceHeader(ble: model.ble) }
                    HStack {
                        Text("MÓDULOS").font(.caption.bold()).tracking(2).foregroundStyle(Palette.gold)
                        Spacer()
                        Text("EDITABLES").font(.caption2).foregroundStyle(Palette.muted)
                    }
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 11) {
                        ForEach(modules, id: \.self) { name in
                            Button {
                                switch name {
                                case "Mandos": tab = 1
                                case "Archivos": tab = 2
                                case "Remoto": tab = 3
                                default: extra = name
                                }
                            } label: {
                                ModuleTile(symbol: metadata[name]?.0 ?? "square", title: name, subtitle: metadata[name]?.1 ?? "")
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("FAVORITOS").font(.caption.bold()).tracking(2).foregroundStyle(Palette.gold)
                    if model.favorites.isEmpty {
                        Panel {
                            Label("Añade señales en Mandos para emitirlas desde aquí.", systemImage: "star")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                        }
                    } else {
                        ForEach(model.favorites.prefix(4)) { signal in
                            Button { model.perform { try await model.transmit(signal) } } label: {
                                Panel {
                                    HStack {
                                        Image(systemName: signal.icon).foregroundStyle(Palette.gold)
                                        Text(signal.title).foregroundStyle(Palette.pale)
                                        Spacer()
                                        Text(signal.kind).font(.caption).foregroundStyle(Palette.muted)
                                        Image(systemName: "bolt.fill").foregroundStyle(Palette.gold)
                                    }
                                }
                            }.buttonStyle(.plain).disabled(!model.ble.connected)
                        }
                    }
                }.padding(18)
            }
            .background(Palette.background)
            .sheet(isPresented: $editing) { HomeEditView(modules: modules) { newModules in moduleString = newModules.joined(separator: ",") } }
            .sheet(item: Binding(get: { extra.map(IdentifiedString.init) }, set: { extra = $0?.value })) { selection in
                NavigationStack {
                    FAPView(model: model)
                }
            }
        }
    }
}
private struct IdentifiedString: Identifiable { let value: String; var id: String { value } }
private struct HomeEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var modules: [String]
    var onSave: ([String]) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("Arrastra para cambiar el orden") {
                    ForEach(modules, id: \.self) { Text($0) }
                        .onMove { source, destination in modules.move(fromOffsets: source, toOffset: destination) }
                }
            }
            .navigationTitle("Personalizar inicio")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Guardar") { onSave(modules); dismiss() } }
            }.environment(\.editMode, .constant(.active))
        }
    }
}
private struct ConnectionView: View {
    @ObservedObject var ble: FlipperBLE
    @Environment(\.dismiss) private var dismiss
    @State private var showOtherDevices = false
    @State private var sharingLog: IdentifiedURL?
    var body: some View {
        NavigationStack {
            List {
                Section("Estado") {
                    LabeledContent("Bluetooth", value: ble.state)
                    if let error = ble.lastError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    if ble.connected {
                        Button("Desconectar", role: .destructive) { ble.disconnect(userInitiated: true) }
                    } else {
                        Button("Volver a buscar") { ble.scan() }
                    }
                }
                Section("Dispositivos disponibles") {
                    if ble.devices.isEmpty {
                        Text("No aparece ningún Flipper. Activa Bluetooth en el Flipper, comprueba que anuncia la conexión y vuelve a buscar. Dispositivos BLE próximos detectados: \(ble.nearbyCount).")
                            .font(.footnote)
                    }
                    ForEach(ble.devices, id: \.identifier) { device in
                        Button { ble.connect(device); dismiss() } label: {
                            HStack { Image(systemName: "cpu"); Text(device.name ?? "Flipper"); Spacer(); Image(systemName: "chevron.right") }
                        }
                    }
                }
                if !ble.otherDevices.isEmpty {
                    Section {
                        DisclosureGroup("Otros dispositivos BLE (\(ble.otherDevices.count))", isExpanded: $showOtherDevices) {
                            ForEach(ble.otherDevices, id: \.identifier) { device in
                                Button {
                                    ble.connect(device)
                                    dismiss()
                                } label: {
                                    Text(device.name ?? "Dispositivo sin nombre")
                                }
                            }
                        }
                    } footer: {
                        Text("Si cambiaste el nombre del Flipper, puedes elegirlo aquí. La app comprobará su servicio RPC antes de conectarse.")
                    }
                }
                Section("Diagnóstico") {
                    Text("El registro se guarda en Archivos → En mi iPhone → Flipper Control. Puedes compartirlo y elegir Descargas en «Guardar en Archivos».")
                        .font(.footnote)
                    Button { sharingLog = IdentifiedURL(url: DiagnosticsLog.shared.fileURL) } label: {
                        Label("Compartir registro de diagnóstico", systemImage: "square.and.arrow.up")
                    }
                }
                Section { Text("Activa Bluetooth en el Flipper y acepta el emparejamiento de iOS.").font(.footnote) }
            }
            .navigationTitle("Conectar Flipper")
            .toolbar { Button("Cerrar") { dismiss() } }
            .sheet(item: $sharingLog) { ShareSheet(url: $0.url) }
        }
    }
}

private struct SignalsView: View {
    @ObservedObject var model: FlipperModel
    @State private var mode = 0
    @State private var irSource = 0
    @State private var universalEntries: [UniversalIREntry] = []
    @State private var universalTitle: String?
    @State private var selectedUniversal: FavoriteSignal?
    @State private var library: [FavoriteSignal] = []
    @State private var loading = false
    @State private var filter = ""
    @State private var searched = false
    @State private var libraryFolder = "/ext/infrared"
    @State private var selectedFavoriteFolder = "General"
    @State private var newFavoriteFolder = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Picker("Emisor", selection: $mode) {
                        Text("INFRARROJOS").tag(0)
                        Text("SUB-GHZ").tag(1)
                    }.pickerStyle(.segmented)
                    if mode == 0 {
                        Picker("Origen IR", selection: $irSource) {
                            Text("Guardados").tag(0)
                            Text("De fábrica").tag(1)
                        }.pickerStyle(.segmented)
                        if irSource == 1 {
                            Text("Elige un código para emitirlo o guardarlo como botón en el Flipper. La primera emisión prepara un archivo individual y puede tardar.")
                                .font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("CARPETAS DE MANDOS", systemImage: "folder.fill").font(.caption.bold()).foregroundStyle(Palette.gold)
                            Picker("Carpeta activa", selection: $selectedFavoriteFolder) {
                                ForEach(model.favoriteFolders, id: \.self) { folder in Text(folder).tag(folder) }
                            }.pickerStyle(.menu)
                            HStack {
                                TextField("Nueva carpeta", text: $newFavoriteFolder).textFieldStyle(.roundedBorder)
                                Button("Crear") {
                                    let folder = newFavoriteFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                                    model.createFavoriteFolder(folder)
                                    if model.favoriteFolders.contains(folder) { selectedFavoriteFolder = folder }
                                    newFavoriteFolder = ""
                                }.disabled(newFavoriteFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Text("Los botones que añadas se guardarán en la carpeta activa.")
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(mode == 0 ? "MANDO UNIVERSAL" : "SEÑALES FAVORITAS", systemImage: mode == 0 ? "tv" : "antenna.radiowaves.left.and.right")
                                .foregroundStyle(Palette.gold).font(.caption.bold())
                            Text(mode == 0 ? "Botones IR asignados · emisión sin probar" : "Señales guardadas · emisión sin probar")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                            let selected = model.favorites.filter { $0.kind == (mode == 0 ? "IR" : "Sub-GHz") && ($0.folder ?? "General") == selectedFavoriteFolder }
                            if selected.isEmpty {
                                Text("No hay botones configurados todavía.").font(.footnote).foregroundStyle(Palette.muted).padding(.vertical, 20)
                            } else {
                                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 9) {
                                    ForEach(selected) { signal in
                                        Button {
                                            model.perform { try await model.transmit(signal) }
                                        } label: {
                                            VStack(spacing: 10) {
                                                Image(systemName: signal.icon).font(.title2)
                                                Text(signal.title).font(.caption.bold()).lineLimit(2)
                                            }
                                            .frame(maxWidth: .infinity).frame(height: 82)
                                            .foregroundStyle(Palette.gold)
                                            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 13))
                                        }.buttonStyle(.plain).disabled(!model.ble.connected)
                                    }
                                }
                            }
                        }
                    }
                    if mode == 1 {
                        Panel {
                            VStack(alignment: .leading, spacing: 13) {
                                Text("READ RAW").font(.headline).foregroundStyle(Palette.pale)
                                Text("Abre Sub-GHz para acceder a Read RAW desde el control remoto; el inicio directo necesita validación con Unleashed DEV.")
                                    .font(.footnote).foregroundStyle(Palette.muted)
                                GoldButton(title: "Abrir Sub-GHz", icon: "dot.radiowaves.left.and.right") {
                                    model.perform { try await model.startSubGHz() }
                                }.disabled(!model.ble.connected)
                            }
                        }
                    }
                    HStack {
                        Text(irSource == 1 && mode == 0 ? "BIBLIOTECAS DE FÁBRICA" : "BIBLIOTECA").font(.caption.bold()).tracking(2).foregroundStyle(Palette.gold)
                        Spacer()
                        Button { loadSignals() } label: { Label("Explorar", systemImage: "arrow.clockwise") }
                            .disabled(!model.ble.connected || loading)
                    }
                    if searched {
                        HStack {
                            if universalTitle != nil {
                                Button { universalTitle = nil; universalEntries = []; selectedUniversal = nil } label: { Label("Atrás", systemImage: "chevron.left") }
                            } else if libraryFolder != (mode == 0 ? (irSource == 0 ? "/ext/infrared" : "/ext/infrared/assets") : "/ext/subghz") {
                                Button { libraryFolder = (libraryFolder as NSString).deletingLastPathComponent; loadSignals() } label: {
                                    Label("Atrás", systemImage: "chevron.left")
                                }.disabled(loading)
                            }
                            Text(universalTitle ?? libraryFolder).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    if loading { ProgressView("Leyendo señales...") }
                    if searched && !loading && library.isEmpty && universalTitle == nil {
                        Text("No se encontraron señales. Revisa el registro de diagnóstico en la tarjeta de conexión.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if !library.isEmpty && universalTitle == nil {
                        TextField("Buscar señal", text: $filter).textFieldStyle(.roundedBorder)
                    }
                    if let universalTitle {
                        Text("\(universalTitle) · \(universalEntries.count) códigos")
                            .font(.headline).foregroundStyle(Palette.gold)
                        TextField("Buscar código", text: $filter).textFieldStyle(.roundedBorder)
                        LazyVStack(spacing: 9) {
                            ForEach(universalEntries.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("\(entry.name) #\(entry.id + 1)").foregroundStyle(Palette.pale)
                                        Spacer()
                                        Text(entry.detail).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2)
                                    }
                                    HStack {
                                        Button("Emitir") {
                                            guard let selectedUniversal else { return }
                                            model.perform { try await model.emulateUniversal(entry, library: selectedUniversal) }
                                        }
                                        Button("Guardar en \(selectedFavoriteFolder)") {
                                            guard let selectedUniversal else { return }
                                            model.perform { try await model.saveUniversal(entry, library: selectedUniversal, folder: selectedFavoriteFolder) }
                                        }
                                    }.buttonStyle(.bordered).tint(Palette.gold)
                                        .disabled(!model.ble.connected || model.busy)
                                }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    ForEach(universalTitle == nil ? library.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) } : []) { signal in
                        HStack {
                            Image(systemName: signal.icon).foregroundStyle(Palette.gold)
                            VStack(alignment: .leading) {
                                Text(signal.title).foregroundStyle(Palette.pale)
                                Text(signal.path).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                if signal.kind == "Folder" {
                                    libraryFolder = signal.path
                                    loadSignals()
                                } else if mode == 0 && irSource == 1 {
                                    loadUniversal(signal)
                                } else if signal.kind == "IR" && signal.index == -1 {
                                    loadIRButtons(signal)
                                } else {
                                    model.addFavorite(signal, to: selectedFavoriteFolder)
                                    model.message("Botón añadido: \(signal.title)")
                                }
                            } label: { Image(systemName: signal.kind == "Folder" ? "chevron.right.circle.fill" : signal.index == -1 ? "list.bullet.circle.fill" : "plus.circle.fill").font(.title2) }
                                .disabled(loading)
                        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !model.favorites.isEmpty {
                        Text("CONFIGURADOS").font(.caption.bold()).tracking(2).foregroundStyle(Palette.gold)
                        ForEach(model.favorites.filter { $0.kind == (mode == 0 ? "IR" : "Sub-GHz") && ($0.folder ?? "General") == selectedFavoriteFolder }) { signal in
                            HStack {
                                Text(signal.title).foregroundStyle(Palette.pale)
                                Spacer()
                                Menu {
                                    ForEach(model.favoriteFolders, id: \.self) { folder in
                                        Button(folder) { model.moveFavorite(signal, to: folder) }
                                    }
                                } label: { Image(systemName: "folder.badge.gearshape").foregroundStyle(Palette.gold) }
                                Button(role: .destructive) {
                                    if let index = model.favorites.firstIndex(of: signal) {
                                        model.deleteFavorites(at: IndexSet(integer: index))
                                    }
                                } label: { Image(systemName: "trash").foregroundStyle(.red) }
                            }
                        }
                    }
                }.padding(18)
            }.background(Palette.background).navigationTitle("Mandos")
                .onChange(of: mode) { _, _ in resetLibrary() }
                .onChange(of: irSource) { _, _ in resetLibrary() }
        }
    }
    private func loadSignals() {
        loading = true
        searched = true
        Task {
            do { library = try await model.listSignals(in: libraryFolder, kind: mode == 0 ? "IR" : "Sub-GHz") }
            catch { model.message(error.localizedDescription) }
            loading = false
        }
    }
    private func loadIRButtons(_ remote: FavoriteSignal) {
        loading = true
        Task {
            do {
                let buttons = try await model.irButtons(in: remote)
                if let index = library.firstIndex(of: remote) {
                    library.replaceSubrange(index...index, with: buttons)
                }
                if buttons.isEmpty { model.message("Este archivo IR no contiene botones con nombre") }
            } catch { model.message(error.localizedDescription) }
            loading = false
        }
    }
    private func loadUniversal(_ remote: FavoriteSignal) {
        loading = true
        Task {
            do {
                universalEntries = try await model.universalEntries(in: remote)
                universalTitle = remote.title
                selectedUniversal = remote
                filter = ""
            } catch { model.message(error.localizedDescription) }
            loading = false
        }
    }
    private func resetLibrary() {
        library = []; universalEntries = []; universalTitle = nil; selectedUniversal = nil
        searched = false; filter = ""
        libraryFolder = mode == 0 ? (irSource == 0 ? "/ext/infrared" : "/ext/infrared/assets") : "/ext/subghz"
    }
}

private struct FilesView: View {
    @ObservedObject var model: FlipperModel
    @State private var localFiles: [URL] = []
    @State private var importer = false
    @State private var sharingURL: IdentifiedURL?
    @State private var renameTarget: FlipperFile?
    @State private var filename = ""
    @State private var folderName = ""
    @State private var makeFolder = false
    @State private var selectedLocal: URL?
    @State private var selectedRemote: FlipperFile?
    @State private var transferInfo = ""
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Panel {
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(Palette.gold)
                        Text("iPhone").font(.headline)
                        Spacer()
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(Palette.gold)
                        Spacer()
                        Image(systemName: "cpu").foregroundStyle(Palette.gold)
                        Text("Flipper").font(.headline)
                    }
                }
                HStack(spacing: 8) {
                    Button { importer = true } label: { Label("Importar de Archivos", systemImage: "square.and.arrow.down") }.font(.caption)
                    Spacer()
                    Button { refreshLocal() } label: { Image(systemName: "arrow.clockwise") }
                    Button { model.perform { try await model.refresh() } } label: { Label("Actualizar", systemImage: "arrow.clockwise") }.font(.caption)
                }
                HStack(spacing: 7) {
                    localColumn
                    flipperColumn
                }
                if model.busy { ProgressView("Transferencia / operación RPC en curso...").font(.caption) }
                HStack(spacing: 12) {
                    Button { copySelectedToFlipper() } label: {
                        Label("Copiar →", systemImage: "arrow.right").frame(maxWidth: .infinity)
                    }.disabled(selectedLocal == nil || !model.ble.connected || model.busy)
                    Button { copySelectedToIPhone() } label: {
                        Label("← Copiar", systemImage: "arrow.left").frame(maxWidth: .infinity)
                    }.disabled(selectedRemote == nil || !model.ble.connected || model.busy)
                }.buttonStyle(.borderedProminent).tint(Palette.gold).foregroundStyle(Palette.background)
                HStack(spacing: 14) {
                    Button { makeFolder = true } label: { Label("Carpeta", systemImage: "folder.badge.plus") }
                    Button { pasteIntoFlipper() } label: { Label("Pegar", systemImage: "doc.on.clipboard") }
                        .disabled(model.clipboard == nil || !model.ble.connected)
                    Spacer()
                    Text("BLE").font(.caption2).foregroundStyle(Palette.muted)
                }.font(.caption)
            }.padding(12).background(Palette.background).navigationTitle("Archivos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Leer /ext") { model.perform { try await model.refresh(path: "/ext") } }
                        Button("Nueva carpeta") { makeFolder = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let destination = documents.appendingPathComponent(url.lastPathComponent)
                        do {
                            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                            try FileManager.default.copyItem(at: url, to: destination)
                        } catch { model.message(error.localizedDescription) }
                    }
                    refreshLocal()
                case .failure(let error): model.message(error.localizedDescription)
                }
            }
            .sheet(item: $sharingURL) { item in ShareSheet(url: item.url) }
            .alert("Nueva carpeta del Flipper", isPresented: $makeFolder) {
                TextField("Nombre", text: $folderName)
                Button("Crear") {
                    let name = folderName
                    model.perform { try await model.mkdir(name) }
                    folderName = ""
                }
                Button("Cancelar", role: .cancel) { }
            } message: { Text("Se creará dentro de \(model.currentPath)") }
            .alert("Renombrar", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Nombre", text: $filename)
                Button("Guardar") {
                    guard let target = renameTarget else { return }
                    let newName = filename
                    model.perform { try await model.rename(target, as: newName) }
                    renameTarget = nil
                }
                Button("Cancelar", role: .cancel) { renameTarget = nil }
            }
            .task { refreshLocal() }
        }
    }
    private var localColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MI IPHONE").font(.caption2.bold()).foregroundStyle(Palette.gold)
            Text("Documentos importados").font(.system(size: 10)).foregroundStyle(Palette.muted)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(localFiles, id: \.path) { url in
                        Button { selectedLocal = url; selectedRemote = nil } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill").foregroundStyle(Palette.gold)
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedLocal == url ? Palette.gold.opacity(0.25) : Palette.elevated, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Copiar") { selectedLocal = url; model.clipboard = (url.path, false) }
                            Button("Enviar a Flipper") { selectedLocal = url; copySelectedToFlipper() }
                            Button("Compartir") { sharingURL = IdentifiedURL(url: url) }
                        }
                    }
                }
            }
            if localFiles.isEmpty { Text("Importa archivos para comenzar").font(.caption2).foregroundStyle(Palette.muted) }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
    }
    private var flipperColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FLIPPER").font(.caption2.bold()).foregroundStyle(Palette.gold)
                Spacer()
                Button { model.perform { try await model.parentDirectory() } } label: { Image(systemName: "arrow.up.left") }
                    .disabled(!model.ble.connected)
            }
            Text(model.currentPath).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.remoteFiles) { file in
                        Button {
                            if file.isDirectory {
                                model.perform { try await model.refresh(path: file.path) }
                                selectedRemote = nil
                            } else { selectedRemote = file; selectedLocal = nil }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: file.icon).foregroundStyle(Palette.gold)
                                Text(file.name).font(.system(size: 11)).lineLimit(2)
                                Spacer(minLength: 0)
                                if file.isDirectory { Image(systemName: "chevron.right").font(.system(size: 8)) }
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedRemote == file ? Palette.gold.opacity(0.25) : Palette.elevated, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Copiar") { model.clipboard = (file.path, true); selectedRemote = file }
                            if !file.isDirectory {
                                Button("Copiar al iPhone") { selectedRemote = file; copySelectedToIPhone() }
                            }
                            Button("Renombrar") { renameTarget = file; filename = file.name }
                            Button("Eliminar", role: .destructive) { model.perform { try await model.remove(file) } }
                        }
                    }
                }
            }
            if model.remoteFiles.isEmpty { Text("Conecta y actualiza").font(.caption2).foregroundStyle(Palette.muted) }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
    }
    private func refreshLocal() {
        localFiles = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil))?.filter { !$0.hasDirectoryPath } ?? []
        localFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private func copySelectedToFlipper() {
        guard let url = selectedLocal else { return }
        model.perform { try await model.importLocal(url) }
    }
    private func copySelectedToIPhone() {
        guard let remote = selectedRemote else { return }
        model.perform {
            let data = try await model.read(remote.path)
            try data.write(to: documents.appendingPathComponent(remote.name), options: .atomic)
            refreshLocal()
            model.message("Copiado al iPhone: \(remote.name)")
        }
    }
    private func pasteIntoFlipper() {
        guard let clip = model.clipboard else { return }
        model.perform {
            let data: Data
            if clip.isRemote { data = try await model.read(clip.path) }
            else { data = try Data(contentsOf: URL(fileURLWithPath: clip.path)) }
            let target = model.currentPath + "/" + URL(fileURLWithPath: clip.path).lastPathComponent
            try await model.write(data, to: target)
            try await model.refresh()
            model.message("Pegado: \(target)")
        }
    }
}

private struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

private struct RemoteView: View {
    @ObservedObject var model: FlipperModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Panel {
                        VStack(spacing: 15) {
                            HStack {
                                Label("PANTALLA EN DIRECTO", systemImage: "display").font(.caption.bold()).foregroundStyle(Palette.gold)
                                Spacer()
                                Text(model.streaming ? "STREAM" : "DETENIDO").font(.caption2).foregroundStyle(model.streaming ? .green : Palette.muted)
                            }
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.88, green: 0.9, blue: 0.84))
                                if let screen = model.screen {
                                    Image(uiImage: screen).resizable().interpolation(.none).scaledToFit().padding(12)
                                } else {
                                    VStack(spacing: 10) {
                                        Image(systemName: "rectangle.on.rectangle.slash").font(.largeTitle)
                                        Text("Conecta y pulsa Iniciar pantalla").font(.caption)
                                    }.foregroundStyle(.black.opacity(0.65))
                                }
                            }.aspectRatio(2, contentMode: .fit)
                            GoldButton(title: model.streaming ? "Detener pantalla" : "Iniciar pantalla", icon: model.streaming ? "stop.fill" : "play.fill") {
                                model.perform {
                                    if model.streaming { try await model.stopScreen() }
                                    else { try await model.startScreen() }
                                }
                            }.disabled(!model.ble.connected)
                        }
                    }
                    Panel {
                        VStack(spacing: 11) {
                            Text("CONTROLES").font(.caption.bold()).tracking(1.8).foregroundStyle(Palette.gold)
                            remoteButton("chevron.up", key: 0)
                            HStack(spacing: 18) {
                                remoteButton("chevron.left", key: 3)
                                remoteButton("circle.fill", key: 4)
                                remoteButton("chevron.right", key: 2)
                            }
                            remoteButton("chevron.down", key: 1)
                            remoteButton("arrow.uturn.backward", key: 5)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(16)
            }.background(Palette.background).navigationTitle("Control remoto")
                .onChange(of: model.ble.connected) { _, connected in
                    if !connected { model.streaming = false; model.screen = nil }
                }
        }
    }
    private func remoteButton(_ icon: String, key: Int) -> some View {
        Button { model.perform { try await model.press(key) } } label: {
            Image(systemName: icon).font(.title2).frame(width: 64, height: 51)
                .foregroundStyle(Palette.gold)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 14))
        }.disabled(!model.ble.connected)
    }
}

private struct FAPView: View {
    @ObservedObject var model: FlipperModel
    @State private var importer = false
    @State private var selectedPath = "/ext/apps/Tools"
    @State private var apps: [FlipperFile] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("FAP MANAGER").font(.caption.bold()).tracking(2).foregroundStyle(Palette.gold)
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Instalar desde archivo").font(.headline)
                        Text("Selecciona una FAP desde Archivos del iPhone. Beta: la comprobación automática de su versión/API con Unleashed DEV aún está pendiente. Instala solo FAPs que ya sepas compatibles.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                        TextField("Carpeta destino", text: $selectedPath)
                            .textInputAutocapitalization(.never).textFieldStyle(.roundedBorder)
                        GoldButton(title: "Seleccionar .fap", icon: "square.and.arrow.down") { importer = true }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Windows y Mac", systemImage: "desktopcomputer").foregroundStyle(Palette.gold)
                        Text("El puente BLE para seleccionar rutas de ordenador se añadirá tras validar su servicio GATT en el equipo real.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
            }.padding(18)
        }.background(Palette.background).navigationTitle("Instalar FAP")
        .fileImporter(isPresented: $importer, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url):
                guard url.pathExtension.lowercased() == "fap" else { model.message("El archivo debe tener extensión .fap"); return }
                let folder = selectedPath
                model.perform { try await model.importLocal(url, folder: folder) }
            case .failure(let error): model.message(error.localizedDescription)
            }
        }
    }
}
