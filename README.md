# PowerMeter · Mac 外设电量监视器

[![Release](https://img.shields.io/github/v/release/polychromate/PowerMeter)](https://github.com/polychromate/PowerMeter/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://github.com/polychromate/PowerMeter)

**版本 0.4.0** · 2026-11-01

菜单栏电量平台：系统电量优先、标准蓝牙/HID 直读兜底，并通过独立安装的设备插件支持罗技 HID++、新盟 2.4G 等厂商协议。本地运行，不联网、不上传任何数据。

![界面](Resources/screenshot.png)

## 下载

不想自己编译？到 [Releases](https://github.com/polychromate/PowerMeter/releases) 下载最新的 `PowerMeter-x.y.z.zip`，解压后把 `PowerMeter.app` 拖进「应用程序」即可。

厂商设备支持以独立插件发布：[PowerMeter-Plugins](https://github.com/polychromate/PowerMeter-Plugins)。下载插件 zip 后，在 App 的「插件 › 安装插件…」中选择即可，升级插件不需要更新主程序。

应用为自签名证书签名（`PowerMeter Dev`，无 Apple 开发者账号、未公证），首次打开若提示「无法验证开发者」：

```bash
xattr -dr com.apple.quarantine /Applications/PowerMeter.app
```

## 当前实测结果（本机 macOS 26.6.2）

| 设备 | 连接方式 | 读数 | 读取通道 |
| --- | --- | --- | --- |
| Logitech MX Keys | Unifying USB 接收器 | ✅ 可读 + ⚡充电状态（实测 0%，充电中） | 插件 HID++ 2.0 `0x1000` |
| Logitech M720 Triathlon | Unifying USB 接收器 | ✅ 可读（实测 50%） | 插件 HID++ 2.0 `0x1000` |
| HAYLOU S35 ANC | 经典蓝牙（HFP/A2DP） | ✅ 可读（实测 90%，与系统设置一致） | IOBluetooth `batteryPercentSingle` |
| 新盟 A99 键盘 | 2.4G USB 接收器（0x3554:FA09） | ✅ 可读（实测 1%→100%，充电状态准确） | 插件厂商私有协议 `0x13` |
| Robin's Earphones | 经典蓝牙（HFP） | ✅ 可读（实测 50–60%） | IOBluetooth `batteryPercentSingle` |
| DJI Mic Mini | 经典蓝牙（HFP） | ✅ 可读（实测 50–60%，偶发单轮 0 读数下一轮恢复） | IOBluetooth `batteryPercentSingle` |
| Logitech K380 | 经典蓝牙（HID） | ✅ 可读（实测 45%） | HID Battery Strength 元素 |
| 英菲克 IN9 鼠标 | 2.4G USB 接收器（0x248A:5B2F） | ❌ 接收器不暴露电量（feature/input 报文全无响应），切蓝牙模式可试 | — |

> 悬浮任意一行可看到原始通道信息，例如 `HID++ 0x1000 · 充电中`。

## 从源码构建

```bash
git clone https://github.com/polychromate/PowerMeter.git
cd PowerMeter
./build.sh              # 编译，产物在 build/PowerMeter.app
open build/PowerMeter.app
```

需要 Xcode Command Line Tools（`xcode-select --install`），不依赖完整 Xcode。

装到「应用程序」以便长期使用：

```bash
cp -R build/PowerMeter.app /Applications/
```

启动后没有 Dock 图标，只在菜单栏出现电量图标（显示当前最需要关注的那台设备的电量）。点击图标展开面板。

- 每 60 秒自动刷新，点击面板右上角可手动刷新
- 鼠标悬停某一行可看到电池类型判定依据、数据来源、协议细节
- 每台设备带电池类型标签：`锂电池`（内置可充电）或 `换电池`（AA/AAA）
- 菜单栏优先显示**未充电的锂电池设备**的电量，可更换电池设备不抢位置
- 未充电的锂电池设备电量 < 15% 时，菜单栏数字变红，面板顶部出现红色提醒条
- 正在充电的设备显示蓝色电量条 + 「⚡充电」标签，图标右下角带闪电徽标
- 数据源运行状态提示（如某通道未就绪）收纳在「关于」弹层里，主面板保持干净

## 电池类型标签

| 标签 | 含义 | 电量低时该做什么 |
| --- | --- | --- |
| `锂电池` | 内置可充电锂电（MX Keys、HAYLOU、妙控系列…） | 插线充电 |
| `换电池` | 使用 AA / AAA 电池（M720 Triathlon、K380、M185…） | 换一节新电池 |
| 无标签 | 判断不出来（型号不在已知库，也没观察到充电） | — |

判定顺序（`Sources/BatteryClassifier.swift`，可靠性从高到低）：

1. `~/Library/Application Support/PowerMeter/battery-types.json` 手动指定；
2. 观察到充电状态 → 锂电池（只有可充电电池才会报 charging）；
3. 罗技 `0x1001` 电压读数 → ≤3.3V 判为 AA/AAA，≥3.4V 判为单节锂电；
4. 已知型号库（MX Keys / MX Master / 妙控系列 / AirPods / M720 / K380 …）；
5. 类型兜底：耳机、触控板基本都是内置锂电。

判断不出来就不显示标签 —— 宁可不说，也不给错信息。型号不在库里时可以自己指定：

```json
{ "m720": "replaceable", "mx keys": "lithium" }
```

写到 `~/Library/Application Support/PowerMeter/battery-types.json` 即可，键按小写子串匹配设备名（重启 App 生效）。

## 菜单栏显示规则

菜单栏只显示**一台**设备的电量，按下面的优先级挑选：

1. 未充电的锂电池设备中电量最低的一台（最需要关注）；
2. 若锂电池设备都在充电 → 显示充电中的锂电池设备；
3. 若没有锂电池设备 → 显示其它有读数的设备。

可更换电池的设备**不会抢占**菜单栏位置：AA 电池没电换一节就好，不需要你惦记。
鼠标悬停菜单栏图标可以看到当前显示的是哪台设备、以及为什么选它。

低电量提醒：未充电的**锂电池**设备电量 < 15% 时，菜单栏数字变红、面板顶部出现红色提醒条。
正在充电的设备不触发提醒（充电中的 0% 不是异常）；可更换电池设备也不触发（换电池即可）。

## 权限

首次启动会请求「蓝牙」权限（`系统设置 › 隐私与安全性 › 蓝牙`），用于 BLE 电池服务扫描和耳机连接状态。
HID++ 读取罗技接收器不需要额外授权。

**「输入监控」权限**（连接新盟等 2.4G 接收器键盘时需要）：macOS 对 GUI App 打开 HID 设备
强制要求该权限（`IOHIDManagerOpen` 返回 `0xE00002E2 kIOReturnNotPermitted`），且系统不会
自动弹窗。App 检测到需要时会调用 `IOHIDRequestAccess` 触发授权请求；若弹窗被拒，请到
`系统设置 › 隐私与安全性 › 输入监控` 手动启用 PowerMeter 后重启 App。命令行运行
`--dump` 不受此限制（继承终端的权限）。

## 电量来源与插件平台

程序把来源分为三层，同一设备自动合并去重：

1. **系统电量**（`Sources/BluetoothBattery.swift`、`Sources/IOBluetoothBattery.swift`）
   - `system_profiler SPBluetoothDataType -json`：AirPods / Beats 等向 macOS 上报的设备。
   - `IOBluetoothDevice` 的 `batteryPercentSingle` / `Left` / `Right` / `Case`：
     第三方耳机电量，与系统设置一致。
   系统有新鲜读数时默认优先使用，成本最低。
2. **通用直接读取**（`Sources/HIDBattery.swift`、`Sources/BLEScanner.swift`）
   - IOKit `BatteryPercent` 系统属性。
   - HID **Battery Strength** 元素（`0x0006 / 0x0020`）的 `GET_REPORT`。
   - BLE GATT `0x180F / 0x2A19`。
   系统没有有效电量时，用这些标准通道兜底。
3. **独立设备插件**（`Sources/PluginPlatform.swift`、`Sources/PluginHIDBridge.swift`）
   插件在独立线程和 JavaScriptCore 上下文中运行，主程序只暴露受控 HID 能力：
   枚举设备、打开设备、读写 Report、接收 Input Report 和等待 RunLoop。
   插件不能直接访问文件或网络；由主程序统一生成设备模型、缓存和界面。

### 插件安装

插件仓库：[polychromate/PowerMeter-Plugins](https://github.com/polychromate/PowerMeter-Plugins)

- 在菜单面板点「插件 › 安装插件…」，选择 `.pmplugin` 目录或 zip。
- 插件默认安装到 `~/Library/Application Support/PowerMeter/Plugins/`。
- 插件独立升级，不要求更新 App；只有平台 API 不兼容时才需要升级主程序。
- 命令行安装：`PowerMeter --install-plugin <zip>`。
- 插件自测：设置 `POWERMETER_PLUGIN_DIR` 后运行 `PowerMeter --plugin-self-test`。

当前插件仓库提供：

- **罗技 HID++**：通过 `0x1000` → `0x1004` → `0x1001` 读取电量和充电状态，
  自动探测 Unifying / Bolt 接收器 1–6 号槽位。
- **新盟 2.4G**：监听 vendor Input Report `0x13`，过滤键盘离线时的占位报文。

插件清单声明 `apiVersion`、`minimumAppVersion` 和来源策略：
`preferPlugin`（优先于系统）、`fallback`（系统/直读失败后兜底）、`pluginOnly`。

> **未连接的设备不进列表**：接收器插在电脑上、或蓝牙里已配对，都不代表设备在线。
> 判定为未连接（收到占位报文 / 长时间无任何报文）的设备会整行隐藏，
> 「关于 › 运行状态」里会写明隐藏原因。

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
├── build.sh                  # 一键编译（swiftc，无需 Xcode）
├── release.sh                # 编译 + 打包 app / 源码到 releases/
├── Info.plist                # LSUIElement 菜单栏应用 + 蓝牙用途说明 + 版本号
├── Sources/
│   ├── main.swift            # 入口，含 --dump / --snapshot 分支
│   ├── AppDelegate.swift     # 状态栏图标、菜单栏选机策略、弹窗、单实例保护
│   ├── Models.swift          # 设备模型、电池类型枚举、低电量阈值
│   ├── BatteryClassifier.swift  # 锂电池 / 换电池判定
│   ├── PluginPlatform.swift  # 插件清单、安装、JS 运行时、来源仲裁
│   ├── PluginHIDBridge.swift # 插件可访问的受控 HID API
│   ├── BluetoothBattery.swift
│   ├── IOBluetoothBattery.swift # 第三方耳机电量（等同系统设置）
│   ├── HIDBattery.swift
│   ├── BLEScanner.swift
│   ├── DeviceStore.swift     # 多源聚合、去重、缓存、菜单栏候选
│   ├── ContentView.swift     # SwiftUI 界面与插件管理
│   └── SnapshotMode.swift    # ImageRenderer 离屏截图
├── Resources/                # 图标与截图
└── releases/                 # 各版本的 app 包与源码包（不进 git）
```

## 说明

- 只允许运行一个实例（罗技接收器是独占设备，多开会导致读不到电量）
- 编译使用系统自带 `swiftc`，产物为 arm64、ad-hoc 签名；不需要安装 Xcode
- 设备休眠时读不到新值，会显示上一次的有效读数（电量条半透明）并在提示中说明

## 版本与归档

仓库用 git 打标签保存每个可用版本：

```bash
git tag -l                     # v0.1.0  v0.2.0
git checkout v0.1.0            # 回到 0.1.0 的完整工程（含当时的 README）
./release.sh                   # 当前版本编译 + 打包到 releases/
```

`releases/` 下每个版本有两个包：`PowerMeter-<版本>.zip`（可直接运行的 app）
和 `PowerMeter-<版本>-source.zip`（该版本 tag 的完整源码，含 README）。

## 版本历史

### 0.4.0 — 2026-11-01

- 升级为可扩展电量平台：系统电量默认优先、标准 HID/BLE 直读兜底、设备插件按策略覆盖。
- 新增独立设备插件机制（API v1）：插件清单、JavaScriptCore 运行时、受控 HID 桥、
  来源策略、安装/升级、插件管理界面和命令行安装/自测。
- 将罗技 HID++ 与新盟 2.4G 从主程序迁移为独立插件，分别发布在
  [PowerMeter-Plugins](https://github.com/polychromate/PowerMeter-Plugins)；
  新增设备支持不再需要更新主程序。
- 拆分 HID `BatteryPercent` 系统属性与 `Battery Strength` 主动直读的来源标记，
  使“系统优先、直读兜底”可被正确裁决。
- 稳定设备缓存键改为规范化设备名，并合并多来源附加信息。
- 应用版本升级为 0.4.0，主程序仍保持本地运行、不联网。

### 0.3.2 — 2026-11-01

- 新增 HID **Battery Strength** 元素通道（usage page `0x0006` / usage `0x0020`）：
  之前只读 IOKit 的 `BatteryPercent` 属性（苹果设备才有），蓝牙键鼠因此读不到电量。
  现在会主动发 `GET_REPORT` 读取该元素并按逻辑量程折算百分比
- 实测：Logitech K380（蓝牙）由「未知」变为 **45%**（report ID 3、报文 `03 09`、量程 0–20）

### 0.3.1 — 2026-11-01

- 修复：键盘关机后仍显示 1%。新盟接收器在键盘未连接时会发送占位报文
  `13 0a 01 00 04 02 01 00`，其中电量字节的 1% 是无效值（连接状态字节为 0x02）；
  内核驱动没有处理这种情况（`online` 标志只置真），旧实现把它当成了真实电量
- **未连接的设备不再出现在列表里**：接收器插在电脑上 / 蓝牙已配对都不等于设备在线。
  新盟键盘在以下情况会整行隐藏——收到「未连接」占位报文、曾经有读数后持续 5 分钟
  无报文、或启动后 60 秒内始终没有报文。「关于 › 运行状态」会说明隐藏原因
- 解析逻辑抽成纯函数 `XinmengReport.parse` 与状态机 `XinmengState`，可脱离硬件回归测试
  （测试用例覆盖真实抓包样本、校验和、开关机与静默超时）

### 0.3.0 — 2026-10-25

- 新增设备适配：新盟 A99 键盘（内置锂电）、英菲克 IN9 鼠标（内置 500mAh 锂电）、
  DJI Mic Mini 无线麦克风（发射器内置 114mAh 锂电，蓝牙直连 Mac 时可识别）、
  Robin's earphone 蓝牙耳机（HFP 上报电量，走 IOBluetooth 通道）
- 新增第六路数据源「厂商私有协议」（`Sources/XinmengHID.swift`）：新盟 2.4G 接收器
  （VID 0x3554:FA09）的电量经 vendor 接口 Input Report `0x13` 上报，协议逆向自
  Linux 内核 hid-xinmeng 驱动；实机验证读数正确（含充电状态）。报文带校验和验证，
  键盘休眠时发出的 0% 占位报文会被忽略（保留最后一次有效读数）。首次使用需在
  「系统设置 › 隐私与安全性 › 输入监控」允许 PowerMeter。键盘闲置休眠期间不发
  报文，敲键唤醒后 30 秒内恢复更新
- 英菲克 IN9 实测结论：2.4G 接收器（0x248A:5B2F）不向系统暴露任何电量通道
  （无 HID BatteryPercent、feature/input 报文均无响应），仅蓝牙模式可尝试读取
- 新增 `microphone` 设备类型：面板显示麦克风图标，排序位于音箱之后
- 设备名识别支持「新盟 / Xinmeng / A99」「英菲克 / inphic / IN9」「DJI Mic / Mic Mini」等
  命名变体；多来源同名设备（带 / 不带品牌前缀）合并更稳
- 电池类型库新增上述型号，低电量提醒（<15% 变红）对这几台设备同样生效
- 运行时快照新增 `notes` 段，便于排查权限 / 数据源问题
- 数据源提示从主面板底部移入「关于」弹层（「运行状态」段），主面板只显示设备
- 蓝牙电量毛刺修复：上报过的设备偶发读到全 0（HFP 抖动）不再显示 0% 并触发
  低电量告警，改为沿用最近一次有效读数并标记数据延迟
- 构建脚本改为优先使用本地自签证书「PowerMeter Dev」签名（无证书环境自动退回
  ad-hoc）；固定签名身份使「输入监控」等 TCC 授权在重新编译后依然有效

### 0.2.0 — 2026-10-25

- 新增电池类型标签：`锂电池`（内置可充电）/ `换电池`（AA、AAA），依据型号库、充电状态、电压区间综合判定，判断不出就不打标签
- 菜单栏改为「优先显示未充电的锂电池设备」，可更换电池设备不再抢占菜单栏位置
- 未充电的锂电池设备电量 < 15% 时，菜单栏数字变红 + 面板顶部红色提醒条
- 支持 `~/Library/Application Support/PowerMeter/battery-types.json` 手动指定电池类型
- 运行时快照新增 `menuBar` 段，便于确认菜单栏当前选了哪台设备

### 0.1.0 — 2026-10-25

首个可用版本，本机实测通过（MX Keys / M720 Triathlon / HAYLOU S35 ANC 三台设备全部正确读数）。

- 五路数据源聚合：罗技 HID++ 2.0、系统蓝牙、HID `BatteryPercent`、IOBluetooth 私有电量、BLE `0x180F`
- 罗技充电状态解析（`0x1000` 状态枚举），界面显示闪电徽标 + 「⚡充电」标签
- 第三方耳机电量（IOBluetooth `batteryPercentSingle`），与系统设置一致
- 设备休眠时沿用最近一次读数并半透明标注
- `--dump` 数据源诊断、`--snapshot` 离屏渲染截图
