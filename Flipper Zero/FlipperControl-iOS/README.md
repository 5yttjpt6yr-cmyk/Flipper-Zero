# Flipper Control 0.9.0

Cliente iOS (iOS 17+) para Flipper Zero desarrollado en SwiftUI con CoreBluetooth y Protobuf RPC.

## Características comprobadas

- Enlace BLE con restauración de estado (`bluetooth-central`).
- Navegación del sistema de archivos `/ext/infrared` y ejecución de señales remotas.
- Streaming del display (128x64 u8g2) a través de Protobuf RPC.
- D-Pad virtual y control remoto interactivo.
- Exploración de mandos universales en `/ext/infrared/assets` y guardado en favoritos locales `/ext/infrared/FlipperControl`.
- Lanzamiento de aplicaciones Sub-GHz integradas.

## Registro y Diagnóstico

El registro de eventos se almacena localmente en `FlipperControl-diagnostico.log` accesible desde la app Archivos (En mi iPhone → Flipper Control) o mediante el panel de diagnóstico para verificar estados de conexión BLE y respuestas del protocolo RPC.

## Compilación

Requisitos: macOS 14+, Xcode 15+ y XcodeGen.

```bash
brew install xcodegen
./build_ipa_macos.sh
```

El script genera el archivo `build/FlipperControl-unsigned.ipa` listo para firma y despliegue.

---
*Aviso: Este proyecto es independiente y no está afiliado con Flipper Devices Inc.*
