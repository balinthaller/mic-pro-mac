#!/bin/zsh
# Build the standalone micproctl CLI. Reuses the upstream Swift protocol
# implementation files directly (single-repo single source of truth).
set -eu
cd "${0:A:h}/.."
mkdir -p build
swiftc -O -module-cache-path build/module-cache-cli \
  Sources/Protocol.swift \
  Sources/AppControlReadPlan.swift \
  Sources/BatteryInfo.swift \
  Sources/DeviceConfig.swift \
  Sources/SystemBattery.swift \
  Sources/WallpaperReadPlan.swift \
  Sources/WallpaperUploadPlan.swift \
  Sources/WallpaperBackup.swift \
  Sources/WallpaperRender.swift \
  cli/Sources/fields.swift \
  cli/Sources/engine.swift \
  cli/Sources/transport.swift \
  cli/Sources/main.swift \
  -framework AppKit -framework CoreBluetooth -framework IOBluetooth \
  -o build/micproctl
echo "built build/micproctl"
