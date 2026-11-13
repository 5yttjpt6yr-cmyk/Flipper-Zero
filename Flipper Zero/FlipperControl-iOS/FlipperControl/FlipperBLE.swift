import Foundation
import CoreBluetooth

@MainActor
final class FlipperBLE: NSObject, ObservableObject {
    private static let restoreID = "es.k41k35.FlipperControl.central.v1"
    private static let deviceKey = "FlipperControl.lastPeripheralID"
    private static let reconnectKey = "FlipperControl.reconnectEnabled"
    // El perfil serie anuncia 0x3080; el servicio GATT RPC usa el UUID de 128 bits.
    static let advertisedServiceUUID = CBUUID(string: "3080")
    static let serviceUUID = CBUUID(string: "8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000")
    static let notifyUUID = CBUUID(string: "19ed82ae-ed21-4c9d-4145-228e61fe0000")
    static let writeUUID = CBUUID(string: "19ed82ae-ed21-4c9d-4145-228e62fe0000")
    static let flowUUID = CBUUID(string: "19ed82ae-ed21-4c9d-4145-228e63fe0000")
    static let rpcStateUUID = CBUUID(string: "19ed82ae-ed21-4c9d-4145-228e64fe0000")

    @Published var state = "Iniciando Bluetooth"
    @Published var devices: [CBPeripheral] = []
    @Published var otherDevices: [CBPeripheral] = []
    @Published var deviceName = "Flipper Zero"
    @Published var connected = false
    @Published var lastError: String?
    @Published var battery: Int?
    @Published var nearbyCount = 0
    private(set) var sessionID = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var flow: CBCharacteristic?
    private var credits = 0
    private var rpcReady = false
    private var rpcAvailable = false
    private var probeInFlight = false
    private var txSubscribed = false
    private var flowSubscribed = false
    private var stateSubscribed = false
    private var pendingWrites: [Data] = []
    private var incoming = Data()
    private var commandNumber: UInt64 = 0
    private var screenFrameCount = 0
    private struct Pending {
        var chunks: [Data]
        var complete: (Result<[Data], Error>) -> Void
        var lastProgress: Date
    }
    private var awaiting: [UInt64: Pending] = [:]
    var unsolicited: ((Data) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID
        ])
    }
    func scan() {
        guard central.state == .poweredOn else {
            state = "Bluetooth no disponible"
            DiagnosticsLog.shared.record("BLE escaneo rechazado: estado \(central.state.rawValue)")
            return
        }
        central.stopScan()
        devices.removeAll()
        otherDevices.removeAll()
        nearbyCount = 0
        lastError = nil
        state = "Buscando Flipper..."
        DiagnosticsLog.shared.record("BLE escaneo iniciado sin filtro de servicios")
        // No filtrar por el UUID GATT: no aparece en el anuncio BLE del Flipper.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func connect(_ device: CBPeripheral) {
        UserDefaults.standard.set(device.identifier.uuidString, forKey: Self.deviceKey)
        UserDefaults.standard.set(true, forKey: Self.reconnectKey)
        central.stopScan()
        peripheral = device
        deviceName = device.name ?? "Flipper Zero"
        state = "Conectando..."
        DiagnosticsLog.shared.record("BLE conectando: \(device.name ?? "sin nombre")")
        central.connect(device, options: nil)
    }
    func disconnect(userInitiated: Bool = false) {
        if userInitiated { UserDefaults.standard.set(false, forKey: Self.reconnectKey) }
        DiagnosticsLog.shared.record("BLE desconexión solicitada")
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
    func resumeKnownConnection() {
        guard central.state == .poweredOn, peripheral == nil,
              UserDefaults.standard.bool(forKey: Self.reconnectKey),
              let rawID = UserDefaults.standard.string(forKey: Self.deviceKey),
              let id = UUID(uuidString: rawID) else { return }
        guard let known = central.retrievePeripherals(withIdentifiers: [id]).first else {
            DiagnosticsLog.shared.record("BLE dispositivo anterior no recuperable; iniciando búsqueda")
            scan()
            return
        }
        central.stopScan()
        peripheral = known
        deviceName = known.name ?? "Flipper Zero"
        state = "Reconectando..."
        DiagnosticsLog.shared.record("BLE recuperando dispositivo conocido: \(id.uuidString)")
        known.delegate = self
        if known.state == .connected {
            known.discoverServices([Self.serviceUUID, CBUUID(string: "180F")])
        } else {
            central.connect(known, options: nil)
        }
    }
    private func retryKnownConnection() {
        guard UserDefaults.standard.bool(forKey: Self.reconnectKey) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.resumeKnownConnection()
        }
    }
    private func clear() {
        sessionID += 1
        connected = false
        peripheral = nil
        tx = nil; rx = nil; flow = nil
        credits = 0; rpcReady = false; rpcAvailable = false; probeInFlight = false
        txSubscribed = false; flowSubscribed = false; stateSubscribed = false
        incoming.removeAll(); pendingWrites.removeAll()
        for (_, pending) in awaiting { pending.complete(.failure(FlipperError.notConnected)) }
        awaiting.removeAll()
    }
    private func flush() {
        guard rpcAvailable, let peripheral, let rx else { return }
        while peripheral.canSendWriteWithoutResponse && credits > 0 && !pendingWrites.isEmpty {
            let next = pendingWrites.removeFirst()
            let count = min(next.count, credits)
            let packet = next.prefix(count)
            if count < next.count { pendingWrites.insert(Data(next.dropFirst(count)), at: 0) }
            credits -= count
            peripheral.writeValue(Data(packet), for: rx, type: .withoutResponse)
        }
    }
    private func sendFramed(_ packet: Data) throws {
        guard rpcAvailable, let peripheral else { throw FlipperError.notConnected }
        let maximum = min(243, max(1, peripheral.maximumWriteValueLength(for: .withoutResponse)))
        var offset = 0
        let all = ProtoWire.framed(packet)
        while offset < all.count {
            let end = min(offset + maximum, all.count)
            pendingWrites.append(all.subdata(in: offset..<end))
            offset = end
        }
        flush()
    }
    func rpc(_ field: Int, payload: Data = Data()) async throws -> [Data] {
        guard rpcAvailable else { throw FlipperError.notConnected }
        commandNumber = (commandNumber % UInt64(UInt32.max)) + 1
        let id = commandNumber
        var main = ProtoWire.integer(1, id)
        main.append(ProtoWire.message(field, payload))
        DiagnosticsLog.shared.record("RPC envío campo=\(field) id=\(id) bytes=\(main.count)")
        return try await withCheckedThrowingContinuation { continuation in
            awaiting[id] = Pending(chunks: [], complete: { continuation.resume(with: $0) }, lastProgress: Date())
            do { try sendFramed(main) }
            catch {
                if let current = awaiting.removeValue(forKey: id) { current.complete(.failure(error)) }
            }
            watchTimeout(id: id)
        }
    }
    func rpcSequence(_ requests: [(field: Int, payload: Data)]) async throws {
        guard rpcAvailable else { throw FlipperError.notConnected }
        guard !requests.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var remaining = requests.count
            var finished = false
            let completed: (Result<[Data], Error>) -> Void = { result in
                guard !finished else { return }
                switch result {
                case .success:
                    remaining -= 1
                    if remaining == 0 { finished = true; continuation.resume() }
                case .failure(let error):
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
            for request in requests {
                commandNumber = (commandNumber % UInt64(UInt32.max)) + 1
                let id = commandNumber
                let main = ProtoWire.integer(1, id) + ProtoWire.message(request.field, request.payload)
                awaiting[id] = Pending(chunks: [], complete: completed, lastProgress: Date())
                DiagnosticsLog.shared.record("RPC secuencia campo=\(request.field) id=\(id)")
                do { try sendFramed(main) }
                catch {
                    if let current = awaiting.removeValue(forKey: id) { current.complete(.failure(error)) }
                    return
                }
                watchTimeout(id: id)
            }
        }
    }
    private func watchTimeout(id: UInt64) {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(12))
                guard let self, let pending = self.awaiting[id] else { return }
                if Date().timeIntervalSince(pending.lastProgress) < 12 { continue }
                self.awaiting.removeValue(forKey: id)
                pending.complete(.failure(FlipperError.timeout))
                DiagnosticsLog.shared.record("RPC sin progreso durante 12 s id=\(id), fragmentos=\(pending.chunks.count)")
                self.disconnect()
                return
            }
        }
    }
    private func consume(_ chunk: Data) {
        incoming.append(chunk)
        while !incoming.isEmpty {
            var offset = 0
            guard let n = ProtoWire.readVarint(incoming, at: &offset) else {
                if incoming.count > 10 { disconnect() }
                return
            }
            guard n < 8_388_608 else { disconnect(); return }
            let length = Int(n)
            guard incoming.count - offset >= length else { return }
            let packet = incoming.subdata(in: offset..<(offset + length))
            incoming.removeSubrange(0..<(offset + length))
            receive(packet)
        }
    }
    private func receive(_ packet: Data) {
        if let frame = ProtoWire.data(packet, field: 22) {
            screenFrameCount += 1
            if screenFrameCount <= 3 || screenFrameCount.isMultiple(of: 50) {
                DiagnosticsLog.shared.record("RPC pantalla fotograma=\(screenFrameCount) bytes=\(ProtoWire.data(frame, field: 1)?.count ?? 0)")
            }
        }
        if ProtoWire.number(packet, field: 1) == 0,
           ProtoWire.number(packet, field: 2) == 2 {
            lastError = "El Flipper rechazó un mensaje RPC"
            disconnect()
            return
        }
        guard let id = ProtoWire.number(packet, field: 1), var current = awaiting[id] else {
            unsolicited?(packet); return
        }
        let status = Int(ProtoWire.number(packet, field: 2) ?? 0)
        let hasNext = ProtoWire.number(packet, field: 3) == 1
        let packetNumber = current.chunks.count + 1
        if status != 0 || packetNumber == 1 || packetNumber.isMultiple(of: 50) || !hasNext {
            DiagnosticsLog.shared.record("RPC respuesta id=\(id) estado=\(status) siguiente=\(hasNext ? 1 : 0) fragmento=\(packetNumber) campos=\(ProtoWire.fields(packet).map(\.number))")
        }
        if status != 0 {
            awaiting.removeValue(forKey: id)
            current.complete(.failure(FlipperError.response(status)))
            return
        }
        current.chunks.append(packet)
        current.lastProgress = Date()
        if hasNext {
            awaiting[id] = current
        } else {
            awaiting.removeValue(forKey: id)
            current.complete(.success(current.chunks))
        }
    }
    private func updateReadyState() {
        let ready = rx != nil && txSubscribed && flowSubscribed && stateSubscribed && rpcReady && credits > 0
        rpcAvailable = ready
        if ready {
            flush()
            if !connected && !probeInFlight {
                probeInFlight = true
                state = "Comprobando RPC..."
                Task { @MainActor in
                    do {
                        let response = try await rpc(39)
                        guard self.rpcAvailable, let version = response.first.flatMap({ ProtoWire.data($0, field: 40) }) else {
                            throw FlipperError.invalidResponse
                        }
                        let major = ProtoWire.number(version, field: 1) ?? 0
                        let minor = ProtoWire.number(version, field: 2) ?? 0
                        self.connected = true
                        self.state = "Conectado · RPC \(major).\(minor)"
                        DiagnosticsLog.shared.record("RPC preparado versión \(major).\(minor)")
                    } catch {
                        self.lastError = error.localizedDescription
                        self.state = "RPC no disponible"
                        DiagnosticsLog.shared.record("RPC prueba inicial falló: \(error.localizedDescription)")
                        self.disconnect()
                    }
                    self.probeInFlight = false
                }
            }
        } else if peripheral != nil {
            connected = false
            state = "Preparando RPC..."
        }
    }
}

extension FlipperBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            DiagnosticsLog.shared.record("BLE central estado=\(central.state.rawValue)")
            switch central.state {
            case .poweredOn:
                self.state = "Preparado para conectar"
                self.resumeKnownConnection()
                if self.peripheral == nil { self.scan() }
            case .poweredOff: self.state = "Activa Bluetooth en Ajustes"; self.clear()
            case .unauthorized: self.state = "Bluetooth sin permiso"; self.clear()
            default: self.state = "Bluetooth no disponible"; self.clear()
            }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
            DiagnosticsLog.shared.record("BLE sesión restaurada por iOS: \(restored.identifier.uuidString)")
            self.peripheral = restored
            self.deviceName = restored.name ?? "Flipper Zero"
            restored.delegate = self
            if restored.state == .connected {
                restored.discoverServices([Self.serviceUUID, CBUUID(string: "180F")])
            } else if UserDefaults.standard.bool(forKey: Self.reconnectKey) {
                central.connect(restored, options: nil)
            }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            self.nearbyCount += 1
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
            let isFlipper = advertised.contains(Self.advertisedServiceUUID)
                || overflow.contains(Self.advertisedServiceUUID)
                || name.localizedCaseInsensitiveContains("flipper")
                || name.localizedCaseInsensitiveContains("unleashed")
            if isFlipper {
                DiagnosticsLog.shared.record("BLE candidato nombre=\(name) rssi=\(RSSI.intValue) servicios=\((advertised + overflow).map(\.uuidString))")
            } else if self.nearbyCount.isMultiple(of: 25) {
                DiagnosticsLog.shared.record("BLE anuncios vistos=\(self.nearbyCount), candidatos=\(self.devices.count)")
            }
            if isFlipper {
                self.otherDevices.removeAll { $0.identifier == peripheral.identifier }
                if !self.devices.contains(where: { $0.identifier == peripheral.identifier }) { self.devices.append(peripheral) }
            } else if !name.isEmpty && self.otherDevices.count < 100 {
                if !self.otherDevices.contains(where: { $0.identifier == peripheral.identifier }) { self.otherDevices.append(peripheral) }
            }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            self.state = "Descubriendo servicios..."
            DiagnosticsLog.shared.record("BLE enlace establecido; descubriendo GATT")
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID, CBUUID(string: "180F")])
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.lastError = error?.localizedDescription ?? "No se pudo conectar"
            DiagnosticsLog.shared.record("BLE conexión falló: \(self.lastError ?? "desconocido")")
            self.clear()
            self.state = "Error de conexión"
            self.retryKnownConnection()
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if let error { self.lastError = error.localizedDescription }
            DiagnosticsLog.shared.record("BLE desconectado: \(error?.localizedDescription ?? "sin error")")
            self.clear()
            self.state = "Desconectado"
            self.retryKnownConnection()
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { self.lastError = error.localizedDescription; self.disconnect(); return }
            DiagnosticsLog.shared.record("BLE servicios GATT=\((peripheral.services ?? []).map { $0.uuid.uuidString })")
            guard peripheral.services?.contains(where: { $0.uuid == Self.serviceUUID }) == true else {
                self.lastError = "Este dispositivo no ofrece el servicio RPC del Flipper"
                self.disconnect()
                return
            }
            for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error { self.lastError = error.localizedDescription; self.disconnect(); return }
            DiagnosticsLog.shared.record("BLE características \(service.uuid.uuidString)=\((service.characteristics ?? []).map { $0.uuid.uuidString })")
            for item in service.characteristics ?? [] {
                switch item.uuid {
                case Self.writeUUID: self.rx = item
                case Self.notifyUUID: self.tx = item; peripheral.setNotifyValue(true, for: item)
                case Self.flowUUID: self.flow = item; peripheral.setNotifyValue(true, for: item); peripheral.readValue(for: item)
                case Self.rpcStateUUID: peripheral.setNotifyValue(true, for: item); peripheral.readValue(for: item)
                case CBUUID(string: "2A19"): peripheral.readValue(for: item)
                default: break
                }
            }
            self.updateReadyState()
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error { self.lastError = error.localizedDescription; self.disconnect(); return }
            DiagnosticsLog.shared.record("BLE notificación \(characteristic.uuid.uuidString)=\(characteristic.isNotifying)")
            switch characteristic.uuid {
            case Self.notifyUUID: self.txSubscribed = characteristic.isNotifying
            case Self.flowUUID: self.flowSubscribed = characteristic.isNotifying
            case Self.rpcStateUUID: self.stateSubscribed = characteristic.isNotifying
            default: break
            }
            self.updateReadyState()
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error { self.lastError = error.localizedDescription; self.disconnect(); return }
            guard let value = characteristic.value else { return }
            if characteristic.uuid == Self.notifyUUID { self.consume(value) }
            else if characteristic.uuid == Self.flowUUID {
                if let count = ProtoWire.bigEndianUInt32(value) {
                    self.credits = Int(count)
                    DiagnosticsLog.shared.record("BLE créditos de flujo=\(self.credits)")
                    guard self.credits > 0 && self.credits <= 1024 else { self.disconnect(); return }
                    self.updateReadyState()
                }
            } else if characteristic.uuid == Self.rpcStateUUID {
                self.rpcReady = value.first == 1
                DiagnosticsLog.shared.record("BLE estado RPC activo=\(self.rpcReady)")
                self.updateReadyState()
            }
            else if characteristic.uuid == CBUUID(string: "2A19") { self.battery = value.first.map(Int.init) }
        }
    }
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in self.flush() }
    }
}

extension FlipperBLE {
    func rpcStream(_ field: Int, payloads: [Data]) async throws -> [Data] {
        guard rpcAvailable else { throw FlipperError.notConnected }
        guard !payloads.isEmpty else { return [] }
        commandNumber = (commandNumber % UInt64(UInt32.max)) + 1
        let id = commandNumber
        return try await withCheckedThrowingContinuation { continuation in
            awaiting[id] = Pending(chunks: [], complete: { continuation.resume(with: $0) }, lastProgress: Date())
            do {
                for (index, payload) in payloads.enumerated() {
                    var main = ProtoWire.integer(1, id)
                    if index != payloads.count - 1 { main.append(ProtoWire.integer(3, 1)) }
                    main.append(ProtoWire.message(field, payload))
                    try sendFramed(main)
                }
            } catch {
                if let current = awaiting.removeValue(forKey: id) { current.complete(.failure(error)) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard let self, let current = self.awaiting.removeValue(forKey: id) else { return }
                current.complete(.failure(FlipperError.timeout))
                self.disconnect()
            }
        }
    }
}
