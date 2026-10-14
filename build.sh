#!/bin/zsh
set -eu
cd "${0:A:h}"
micpro_app_version=$(cat VERSION)
micpro_build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)
micpro_git_revision=$(git rev-parse --short HEAD 2>/dev/null || echo source)
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then micpro_git_revision="${micpro_git_revision}-dirty"; fi
mkdir -p 'build/Mic Pro Probe.app/Contents/MacOS' 'build/Mic Pro Probe.app/Contents/Resources' logs
cp scripts/codex-quota.py 'build/Mic Pro Probe.app/Contents/Resources/codex-quota.py'
swiftc -O -module-cache-path build/module-cache Sources/*.swift -framework AppKit -framework Carbon -framework CoreBluetooth -framework CoreAudio -framework IOBluetooth -o 'build/Mic Pro Probe.app/Contents/MacOS/MicProProbe'
swiftc -module-cache-path build/module-cache Sources/DeviceConfig.swift Sources/SystemBattery.swift scripts/BatteryReader/main.swift -framework IOBluetooth -o 'build/Mic Pro Probe.app/Contents/MacOS/MicProBatteryReader'
cat > 'build/Mic Pro Probe.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.micpromac.public-preview</string>
<key>CFBundleExecutable</key><string>MicProProbe</string>
<key>CFBundleName</key><string>Mic Pro Probe</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSUIElement</key><true/>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>连接你的 Insta360 Mic Pro，验证蓝牙控制服务并读取设备设置。</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>连接你的 Insta360 Mic Pro，读取设备设置。</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add CFBundleShortVersionString string ${micpro_app_version}" 'build/Mic Pro Probe.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${micpro_build_number}" 'build/Mic Pro Probe.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c "Add MicProGitRevision string ${micpro_git_revision}" 'build/Mic Pro Probe.app/Contents/Info.plist'
if [[ "${MICPRO_ADHOC:-0}" == "1" ]]; then
  codesign --force --sign - --timestamp=none "build/Mic Pro Probe.app/Contents/MacOS/MicProBatteryReader"
  codesign --force --sign - --timestamp=none "build/Mic Pro Probe.app"
  codesign --verify --strict "build/Mic Pro Probe.app"
else
  python3 scripts/sign-app.py
fi
