# CarWithin Local 纯蜂窝单机分支收尾需求文档（PRD）

## 1. 背景与目标

本需求文档记录 `codex/carplay-no-wifi` 分支针对「单台未越狱 iPhone（iPhone 17 Pro Max，iOS 27.0.1）不接外设、不连接 Wi-Fi 网络、仅走 5G 蜂窝数据启动 iOS 原生 CarPlay」的可行性核查结论，以及本分支的收尾整理计划。

### 1.1 目标
- 准确沉淀 iOS 27.0.1 真机实测与系统框架静态核对的最终结论，避免误导使用者继续在已确认受系统门禁阻断的路径上重复排查。
- 明确「关闭 Wi-Fi」「开启 Wi-Fi 但不加入任何网络」「虚拟 USB / VPN（`utun*`）/ 本机回环（`lo0`）」三类场景均被 `airplayd` 传输接口资格检查阻断的技术依据。
- 完成代码与文档改动自检、回归测试与 iOS 工程编译验证，并将本分支未提交改动整理为清晰提交。

### 1.2 非目标
- 不尝试绕过 iOS 沙盒、私有权限检查或未公开内核限制。
- 不在本分支引入需要外部硬件（如无网迷你 Wi-Fi AP、USB CarPlay 主机）或仿 CarPlay 自研驾驶 UI 的新功能；此类方向需另立需求确认后再实施。

---

## 2. 技术核查结论汇总

| 维度 | 核查依据 | 结论 |
| --- | --- | --- |
| iAP2 配件链路 | iPhone 17 Pro Max（iOS 27.0.1，24A446）build 19 真机复测 | `ACCTransportClient` 虚拟配件、MFi 认证（`0xAA00`–`0xAA05`）、识别（`0x1D00`–`0x1D02`）及 `0x4301` 均已被系统接受并送达 `carkitd` / `airplayd`。 |
| CarPlay 发现入口 | `AirPlaySender` `APEndpointManagerCarPlayCreate` | 系统仅创建 `USB`、`WiFi`、`Session` 三类 CarPlay 浏览器，均受 `APConnectivityHelper` 与 `carPlayHelperSession_updateNetworkAndSessionState` 门禁控制，无回环/蜂窝/VPN 入口。 |
| Wi-Fi 关闭或开启但未入网 | `APConnectivityHelperPopulateCurrentWiFiNetworkInfo` 与 `carPlayHelperSession_wifiNetworkChanged` | 仅当 `CWFInterface` 关联真实 AP、`currentKnownNetworkProfile.isCarPlay == YES` 且 `carplayUUID` 匹配并存在本地 IP 时，才设置 `wifiInterfaceName`。关闭 Wi-Fi、开启 Wi-Fi 但未连网或仅开个人热点均触发 `WiFi eligible: N (No Network SSID)`。 |
| 虚拟 USB / VPN / 回环 | `_APConnectivityHelperHandleUSBNetworkChangedEvent` 与 `CoreUtils` `SocketGetInterfaceInfo` | 仅带 `IFEF_DIRECTLINK`（`0x10`）或 `IFNET_SUBFAMILY_USB`（`0x08`，且需 `isWiredCarPlaySimulator`）的接口可进入有线候选。`lo0`、`utun*`（含 `NEPacketTunnelProvider` / LocalDevVPN）、`pdp_ip*` 均返回类型 `1`，无法成为 CarPlay 接口；普通沙盒 App 无法创建带上述标志的内核网卡。 |
| 实机 USB 调试线对照 | iPhone 17 Pro Max（iOS 27.0.1）接线 / 拔线复测 | 接线报 `USB transport type mismatch:8, Sim:No`，拔线报 `No Network Interface`，与静态逻辑完全一致。 |

---

## 3. 执行计划与验收标准

### 3.1 文档与界面整理
1. 保留并核对当前工作区对 [App/ReceiverViewController.swift](../App/ReceiverViewController.swift)、[App/SameDeviceProbe.swift](../App/SameDeviceProbe.swift)、[README.md](../README.md) 与 [README.zh-CN.md](../README.zh-CN.md) 的文案收敛，将本机模式清晰标示为实验性连接测试，并如实说明 iPhone 17 Pro Max / iOS 27.0.1 实测未建立会话。
2. 在 [docs/LOCAL-ONLY.md](../docs/LOCAL-ONLY.md) 补充：
   - Wi-Fi 开启但未加入任何网络（及个人热点）同样无法满足 `CWFInterface` / `isCarPlay` / `carplayUUID` 条件的静态依据；
   - `APEndpointManagerCarPlay` 三浏览器架构与 `SocketGetInterfaceInfo` 内核标志门禁（说明为何回环、VPN `utun*` 与虚拟假 USB 均不可行）。

### 3.2 验证要求
- 核心单测通过：`swift test --configuration release`
- 本机 socket 隔离与回送烟测通过：`bash Tools/test_local_network.sh`
- iOS Release 无签名构建通过：`bash Tools/build_local_ipa.sh`（确认 App 层 Swift 修改无编译错误且 IPA 校验通过）
- 工作区变更干净，按约定提交至 `codex/carplay-no-wifi` 分支（不自动 push）。

---

## 4. 后续可选演进方向（待用户另行确认）

1. **原 Wi-Fi 模式 + 无外网本地 AP（保留原生 CarPlay + 5G 蜂窝上网）**：通过不配置默认网关的迷你本地 Wi-Fi AP 满足 `airplayd` Wi-Fi 关联条件，在线业务继续走蜂窝数据。
2. **纯单机纯蜂窝仿 CarPlay 驾驶桌面（放弃原生 CarPlay 渲染）**：在 App 内提供横屏大按钮车载 UI（地图导航、音乐控制与音频路由），无需 Wi-Fi 与任何外部设备。
