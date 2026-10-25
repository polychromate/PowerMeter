# PowerMeter · Mac 外设电量监视器

**版本 0.1.0** · 2026-10-25 · 首个可用版本

菜单栏小工具，实时显示罗技键鼠、蓝牙耳机的电量。本地运行，不联网、不上传任何数据。

![界面](Resources/screenshot.png)

## 当前实测结果（本机 macOS 26.6.2）

| 设备 | 连接方式 | 读数 | 读取通道 |
| --- | --- | --- | --- |
| Logitech MX Keys | Unifying USB 接收器 | ✅ 可读 + ⚡充电状态（实测 0%，充电中） | HID++ 2.0 `0x1000` |
| Logitech M720 Triathlon | Unifying USB 接收器 | ✅ 可读（实测 50%） | HID++ 2.0 `0x1000` |
| HAYLOU S35 ANC | 经典蓝牙（HFP/A2DP） | ✅ 可读（实测 90%，与系统设置一致） | IOBluetooth `batteryPercentSingle` |

> 悬浮任意一行可看到原始通道信息，例如 `HID++ 0x1000 · 充电中`。

## 运行

```bash
cd PowerMeter
./build.sh              # 编译，产物在 build/PowerMeter.app
open build/PowerMeter.app
```

装到「应用程序」以便长期使用：

```bash
cp -R build/PowerMeter.app /Applications/
```

启动后没有 Dock 图标，只在菜单栏出现电量图标（显示当前最低电量）。点击图标展开面板。

- 每 60 秒自动刷新，点击面板右上角可手动刷新
- 鼠标悬停某一行可看到数据来源、协议细节
- 任意设备低于 15% 时，菜单栏图标变红
- 正在充电的设备显示蓝色电量条 + 「⚡充电」标签，图标右下角带闪电徽标

## 权限

首次启动会请求「蓝牙」权限（`系统设置 › 隐私与安全性 › 蓝牙`），用于 BLE 电池服务扫描和耳机连接状态。
HID++ 读取罗技接收器不需要额外授权。

## 五路数据来源

程序按精度从高到低聚合五类通道，同一设备自动合并去重：

1. **罗技 HID++ 2.0**（`Sources/LogitechHIDPP.swift`）
   直接与 Unifying / Bolt 接收器或蓝牙直连的罗技外设对话，按 `getFeature` 解析
   `0x1000 BATTERY_LEVEL_STATUS` → `0x1004 UNIFIED_BATTERY` → `0x1001 BATTERY_VOLTAGE`（电压换算）。
   `0x1000` 的第三个参数字节是充电状态枚举（0 放电 / 1 充电 / 2 即将充满 / 3 已充满 / 4 慢充），
   界面据此显示「⚡充电」徽标；`0x1004` 按 v4 规范先用 fn0 读能力、再用 fn1 读电量。
   接收器会自动探测 1–6 号配对槽位；设备休眠时沿用最近一次读数并标注。
2. **系统蓝牙**（`Sources/BluetoothBattery.swift`）
   解析 `system_profiler SPBluetoothDataType -json` 的已连接设备，可读 AirPods / Beats 等
   向 macOS 上报电量的设备（含左右耳、充电盒）。
3. **HID 属性**（`Sources/HIDBattery.swift`）
   枚举 IOHID 设备的 `BatteryPercent`，覆盖苹果妙控系列与部分第三方 HID 设备。
4. **蓝牙上报**（`Sources/IOBluetoothBattery.swift`）
   读取 `IOBluetoothDevice` 的私有属性 `batteryPercentSingle` / `batteryPercentLeft` /
   `batteryPercentRight` / `batteryPercentCase`。**这正是 macOS「系统设置 → 蓝牙」里
   第三方便携耳机电量的来源**，`system_profiler` 并不导出这些值。
5. **BLE 电池服务**（`Sources/BLEScanner.swift`）
   扫描 GATT `0x180F` 服务并读取 `0x2A19`，覆盖支持 BLE 电量上报的耳机与鼠标。

## 关于耳机（HAYLOU S35 ANC）

一开始结论是「读不到」，后来定位到真正的通道，现已正常显示：

- `system_profiler SPBluetoothDataType` 与 IORegistry 里确实**没有** `device_batteryLevel*`
  —— 这条路只对 AirPods 等 Apple 设备有效，容易让人误判为「耳机不上报」；
- CoreBluetooth 也扫不到它（经典蓝牙连接时不开放 BLE 广播），没有 `0x180F` 电池服务；
- 真正的数据在 `IOBluetoothDevice` 的私有属性 `batteryPercentSingle` 上：bluetoothd 收到耳机
  HFP `AT+IPHONEACCEV` 后写入该属性，系统设置面板读的就是它。

因此 App 增加了一路 IOBluetooth 数据源，现在与系统设置显示的数值一致（实测 90%）。
工程上有个坑：`+[IOBluetoothDevice pairedDevices]` **不能在主线程调用**
（内部会等主队列信号量，直接死锁/崩溃），必须在后台线程；而且它只能在
LaunchServices 启动的 App 里调用，终端里直接执行二进制会因 TCC 无法归属而被内核中止，
所以 `--dump` 会跳过这一路并给出提示。

## 命令行诊断

```bash
# 打印各数据源的原始抓取结果，排查某台设备为什么没有电量
build/PowerMeter.app/Contents/MacOS/PowerMeter --dump

# 离屏渲染界面截图（不需要屏幕录制权限）
build/PowerMeter.app/Contents/MacOS/PowerMeter --snapshot out.png
```

运行时的最近一次扫描结果也会写到
`~/Library/Application Support/PowerMeter/last-scan.json`，便于排查。

## 文件结构

```
PowerMeter/
├── build.sh                  # 一键编译打包（swiftc，无需 Xcode）
├── Info.plist                # LSUIElement 菜单栏应用 + 蓝牙用途说明
├── Sources/
│   ├── main.swift            # 入口，含 --dump / --snapshot 分支
│   ├── AppDelegate.swift     # 状态栏图标、弹窗、单实例保护
│   ├── Models.swift          # 设备模型、类型推断、电量配色
│   ├── LogitechHIDPP.swift   # HID++ 协议实现 + 后台线程会话
│   ├── BluetoothBattery.swift
│   ├── IOBluetoothBattery.swift # 第三方耳机电量（等同系统设置）
│   ├── HIDBattery.swift
│   ├── BLEScanner.swift
│   ├── DeviceStore.swift     # 多源聚合、去重、缓存
│   ├── ContentView.swift     # SwiftUI 界面
│   └── SnapshotMode.swift    # ImageRenderer 离屏截图
└── Resources/                # 图标与截图
```

## 说明

- 只允许运行一个实例（罗技接收器是独占设备，多开会导致读不到电量）
- 编译使用系统自带 `swiftc`，产物为 arm64、ad-hoc 签名；不需要安装 Xcode
- 设备休眠时读不到新值，会显示上一次的有效读数（电量条半透明）并在提示中说明

## 版本历史

### 0.1.0 — 2026-10-25

首个可用版本，本机实测通过（MX Keys / M720 Triathlon / HAYLOU S35 ANC 三台设备全部正确读数）。

- 五路数据源聚合：罗技 HID++ 2.0、系统蓝牙、HID `BatteryPercent`、IOBluetooth 私有电量、BLE `0x180F`
- 罗技充电状态解析（`0x1000` 状态枚举），界面显示闪电徽标 + 「⚡充电」标签
- 第三方耳机电量（IOBluetooth `batteryPercentSingle`），与系统设置一致
- 设备休眠时沿用最近一次读数并半透明标注
- `--dump` 数据源诊断、`--snapshot` 离屏渲染截图
