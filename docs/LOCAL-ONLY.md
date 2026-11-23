# CarWithin Local：仅本机与蜂窝联网实验分支

这个分支尝试让同一台 iPhone 生成、接收、显示并操作 CarPlay，同时由蜂窝网络为地图、音乐等联网功能提供数据。默认使用本机回环连接，不要求安装外部 VPN，不把 CarPlay 画面通过 HTTP 服务分享给其他设备。

**iPhone 17 Pro Max（iOS 27.0.1）实测无法通过本机回环启动纯蜂窝 CarPlay。** build 19 的请求已到达 iOS 的 CarPlay 服务，系统在建立 TCP 控制连接之前判定无线和有线传输均不符合条件。

## iOS 27.0.1 真机复测

2026-11-23 使用 iPhone 17 Pro Max（iOS 27.0.1，24A446）测试 build 19。两轮均在系统设置关闭 Wi-Fi，保留 5G，使用 `127.0.0.1:7000`。第一轮接线读取实时日志。第二轮拔线后独立启动，等 App 自动停止后接回 Mac 读取历史日志。

| 观察位置 | 结果 |
| --- | --- |
| CarWithin | iAP2 配件认证和识别成功，收到 `0x4300` 后发送 `0x4301`。 |
| `accessoryd` / `carkitd` | 识别出启动请求携带的 `127.0.0.1` 有线地址，进入无 Wi-Fi 凭据的会话启动流程。 |
| `airplayd`，接 USB 调试线 | `WiFi eligible: N (No Network SSID), USB eligible: N (USB transport type mismatch:8, Sim:No)`。 |
| `airplayd`，拔掉 USB 线 | 四次 `0x4301` 均收到相同结果 `WiFi eligible: N (No Network SSID), USB eligible: N (No Network Interface)`。 |
| CarWithin | 未收到控制连接，自动停止。未建立画面和触控通道。 |

`airplayd` 在尝试连接接收端之前检查传输接口。这次请求已通过配件认证，也被系统解析为会话启动请求。回环和蜂窝网络在该次会话中均未成为可用的 CarPlay 传输接口，Mac 的 USB 调试连线也没有提供符合条件的有线接口。此前 LocalDevVPN 的测试只验证了 App 的 TCP 回送，尚未观察到系统采用该接口。iOS 26.1 的实现也按系统检测到的 Wi-Fi 或 USB 接口检查传输资格。[APTransport 的接口判断](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APTransport.mm#L4659)

### 不连接外部 Wi-Fi 且仅使用一台 iPhone

- **仅存在 Wi-Fi 与 USB 两类媒体通道**：`AirPlaySender` 中的 `APEndpointManagerCarPlay` 仅创建 `USB`、`WiFi` 和 `Session` 三个 CarPlay 浏览器，三者均经过 `APConnectivityHelper` 与 `carPlayHelperSession_updateNetworkAndSessionState` 的接口资格检查，没有回环、蜂窝或 VPN 专用入口。[APEndpointManagerCarPlay 初始化](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/AirPlaySender.framework/AirPlaySender/AirPlaySender_10.mm#L3366)
- **Wi-Fi 开启但不加入任何网络同样不满足条件**：`APConnectivityHelper` 通过 `CWFInterface` 读取当前关联的 `networkName` 与 `currentKnownNetworkProfile`，而 `carPlayHelperSession_wifiNetworkChanged` 仅在 `wifiNetworkIsCarPlay` 为真时才记录 `wifiInterfaceName` 与 `wifiCurrentUUID`，后续还会校验它与 `carkitd` 保存的 `carplayWiFiUUID` 一致且网卡具备本地 IP。无论在系统设置关闭 Wi-Fi、开启 Wi-Fi 但未关联 AP，还是仅开启本机个人热点，客户端关联 SSID 均为空，仍会触发 `WiFi eligible: N (No Network SSID)`。[Wi-Fi 信息读取](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APConnectivityHelperPopulateCurrentWiFiNetworkInfo.mm#L6) · [Wi-Fi 状态过滤](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APTransport_07.mm#L9795)
- **纯软件无法虚拟 USB 或用 VPN 网卡替代**：`_APConnectivityHelperHandleUSBNetworkChangedEvent` 监听 `SCDynamicStore` 的网卡链路状态并调用 `CoreUtils` 的 `SocketGetInterfaceInfo` 按内核 `ioctl` 标志分类，仅接受带 `IFEF_DIRECTLINK`（`0x10`）或 `IFNET_SUBFAMILY_USB`（`0x08`）的接口。`lo0`（回环）、`utun*`（`NEPacketTunnelProvider` / LocalDevVPN）与 `pdp_ip*`（蜂窝）均返回通用类型 `1`，不会被加入有线候选列表；未越狱 iOS 沙盒应用也无法在内核创建带上述标志的虚拟网卡。[USB 网卡筛选](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APTransport.mm#L4108) · [SocketGetInterfaceInfo 分类](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/CoreUtils.framework/CoreUtils/CoreUtils_01.mm#L4018)
- 直接调用 CarKit 的会话请求服务仍会将请求交给 `APTransport`。在所核对的 iOS 26.1 实现中，该服务还会检查调用方的系统签名权限 `com.apple.private.carkit.sessionRequest`。普通应用开发签名无法授予该权限。[CarKit 权限检查](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/CarKit.framework/CarKit/CARSessionRequestAgent.mm#L92) · [APTransport 接收请求](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APCarSessionRequestHandler.mm#L184)
- 有线模拟器有独立的系统状态，`carkitd` 从自身状态设置它。`APTransport` 仍要求系统检测到活动的 USB 网络接口及其地址。Apple 提供的 CarPlay 模拟器运行在 Mac 上。[CarKit 的会话初始化](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/usr/libexec/carkitd/carkitd.mm#L5190) · [Apple CarPlay 开发者资料](https://developer.apple.com/carplay/)

所核对的入口均未提供符合这组要求的本机媒体通道。真机失败发生在 RTSP、配对和视频协商之前。当前尚无可在目标 iPhone 上交付的纯蜂窝同机 CarPlay 版本。

## 基线与应用身份

| 项目 | 值 |
| --- | --- |
| 上游 | [xmz28/CarWithin](https://github.com/xmz28/CarWithin) |
| 源码版本 | 1.0.3，build 15 |
| 源码发布提交 | `dfb6c25a239eb52e7fab39c1299cb4120a0780f0`，tag `v1.0.3` |
| 本分支基线 | `4cdc0f3d0d319bb5fc957932cf1cacf272c02b50`，包含该版本后的 README 更新 |
| 显示名称 | CarWithin Local |
| Bundle ID | `com.evandbg.carwithin.local` |
| 本分支应用版本 | 1.0.3，build 19 |
| 最低部署版本 | iOS 16.0；实际兼容性仍需按设备与系统验证 |

使用独立 Bundle ID 是为了和上游安装版本区分。新的签名或 Bundle ID 通常不会自动继承旧 App 的容器与 Keychain 身份，安装本分支后应查看其身份状态。

## build 19：核对 StartSession 配对标识的历史记录

build 18 的最新反馈已覆盖完整 45 秒等待窗口。两种模式都没有“控制入站”；之前 8–13 秒手动停止的观察局限已由这两轮补齐。反馈仍未包含完整 iOS 版本和 Wi-Fi 关联状态，因此不能据此给某个具体 iOS 或纯蜂窝状态作兼容性结论。

| 阶段 | 直接回环 | LocalDevVPN |
| --- | --- | --- |
| RTSP 监听器 | `127.0.0.1:7000` 就绪 | `10.7.1.1:7000` 就绪，App 回送探测通过 |
| iAP2 配件认证和识别 | iOS 接受 | iOS 接受 |
| StartSession | 向 `127.0.0.1:7000` 请求，随后重试 | 向 `10.7.0.1:7000` 请求，随后重试 |
| 完整观察窗口 | 21:47:52–21:48:37，45 秒 | 21:49:06–21:49:51，45 秒 |
| 控制连接、画面 | 没有控制入站，自动超时 | 没有控制入站，自动超时 |

“没有控制入站”是 App 的观察，不能替代抓包，也不能单独区分系统未发起连接、路由阻断或接口资格未通过。MFi 认证已被 iOS 接受，因此这份日志不支持要求用户重新生成那三个认证文件。

### 为什么尝试配对标识，而不是沿用 build 18 的字段解释

build 18 参考 DiPlay，将 `0x4301` field 4 当作接收器 Ed25519 公钥并编码为 64 字符 hex。**此前把这视为协议确定要求，依据不充分。** 新核对的 iOS 26.1 静态处理链如下：

| 处理阶段 | 实际数据流 |
| --- | --- |
| CoreAccessories 解析 `0x4301` | field 4 以字符串解析，传入 `platform_CarPlay_startSession` 的第 10 个参数 |
| CoreAccessories / carkitd / CarKit | 以历史名称 `publicKey` 传到 `CARSessionRequestHost.publicKey` |
| APTransport 创建接收端属性 | `host.publicKey` 被赋给 `publicCUAirPlayPairingIdentity` |
| APTransport 属性与 TXT 映射 | 上述身份属性对应 `pi`；独立的 `publicKey` 属性才对应 `pk` |

以上来自公开反编译的固定 iOS 26.1 / 23B85 仓库提交 `90aa0cfe59d9682b4265e1354c8b19ec3c7823ab`：[field 4 解析及传递](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/CoreAccessories.framework/Support/CoreAccessories/CoreAccessories_15.mm)、[平台层字段](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/CoreAccessories.framework/Support/CoreAccessories/CoreAccessories_08.mm)、[carkitd](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/usr/libexec/carkitd/carkitd.mm)、[CarKit host](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/CarKit.framework/CarKit/CARSessionRequestHost.mm)、[APTransport 赋值](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APTransport.mm)、[pi/pk 映射](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/APTransport.framework/APTransport/APTransport_02.mm)。这是静态实现证据，不是 Apple 对私有接口的兼容性承诺，也没有证明当前手机已经进入这条分支。

独立实现 [LIVI 的 helper](https://github.com/f-io/LIVI/blob/4451f8f8b927032dd59708ab2f1591548410139e/native/crates/livi-helper/src/lib.rs) 将 `start.pairing_id` 填入名为 `public_key` 的配置，[wired/wireless StartSession 构造](https://github.com/f-io/LIVI/blob/4451f8f8b927032dd59708ab2f1591548410139e/native/crates/livi-helper-stack/src/bringup.rs) 都使用这个值。另一方面，[DiPlay](https://github.com/shihabal3amri/DiPlay/blob/615b32ce0b40cd0b99ce94ba23a512001553684f/shared/src/main/java/com/shilapi/xcertplay/orchestration/CarPlayController.kt) 确实使用真实公钥 hex，而其配对 ID 是另一个 UUID。不同实现的冲突仍然存在；不能将某项目整体成功等同于“只改变 field 4 的对照实验”。

### 这版具体改变什么

`NativeReceiver` 使用活动 `AirPlayCredentials.identifier`，与该对象用于 PairSetup/PairVerify 的持久标识一致。本 App 首次建立身份时生成 UUID，但此次升级不额外生成标识或密钥。监听器在自己的队列取得实际端口和标识快照，通过已有启动 token 检查传入 `SameDeviceProbe`；iAP2 建链前将字段编码为原样 UTF-8 加 NUL，同次启动重试复用编码。

本地实现检查非空、UTF-8 字节数不超过 252、无空白或控制字符，且不强制标识必须为 UUID。远端 iPad 的原请求继续保留未知身份空字段，不把发送手机的身份当作远端身份。field 4 值属于 AirPlay 会话身份，和导入的 MFi P-256 配件认证材料是不同用途；已经成功载入并认证的材料无需重建。

**本次属于有依据的单变量试验，不是已确定根因的修复。** 地址/绑定、端口、ACC 传输类型、地址组、Wi-Fi 凭据省略、Bonjour/HTTP 共享策略、重试和超时都不改变。`0x4300` 可用性为 1 不表示回环或 utun 已成为系统认可的 CarPlay 媒体接口；没有 Wi-Fi 凭据也不自动满足有线接口条件。

每次启动新增系统版本、App build，以及 field 4 使用 `pi` 的语义和长度日志，不打印标识全文、证书或私钥。复测按同样网络条件单次启动，等待自动结果；无控制连接约 45 秒停止，控制已建立但没有视频样本时总启动期限为 75 秒。请附系统设置中 Wi-Fi 的实际状态和蜂窝是否可用。

若新版本仍无控制入站，下一步需要系统侧证据：可按 [Apple 的设备日志指引](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs) 用 Mac“控制台”选择已连接且信任的 iPhone，开始采集并复现一次，记录准确时间，然后分别查找 `airplayd`、`carkitd`、`APBrowserCarSessionHelper`、`CarPlay` 相关消息。不同系统的进程名和可见日志可能不同；USB 接线会改变测试环境，应明确记录是否接线，不能把接线结果自动当作原蜂窝环境的对照。日志不一定显示拒绝原因；不要为了获得日志先改网络接口或开启额外广告。

## build 18：公钥取值试验与连接诊断（历史记录）

此版填入 32 字节 Ed25519 公钥的 64 字符 hex，补充了“控制入站”、拒绝/等待/失败/就绪以及启动前校验失败日志，保留了停止/重启的过期回调保护。真机结果为两种本机模式完整等待 45 秒仍无控制入站。公钥字段的解释已按上节校正；历史发布说明保留当时实现，并附后续说明。

## build 17：本机监听器修复

针对“LocalDevVPN 本机回送已验证”后立即出现 `Network.NWError 22 / Invalid argument` 的反馈，统一了控制监听器和回送探测使用的创建入口。指定本地地址时，完整的地址与端口只写入 `requiredLocalEndpoint`，由 `NWListener(using:)` 创建；不再向 `on:` 重复传入固定端口。原 Wi-Fi 模式没有指定本地地址，继续使用独立的监听端口参数。指定地址没有改变为通配监听。

网络实测脚本新增固定端口的 ready 状态、TCP 回送与其他本机接口拒绝检查，以及端口占用和自动端口回退检查。此前自动端口探测成功，不能覆盖固定控制端口的初始化行为。

每次实际启动会记录来源与尝试编号，监听器日志包含模式、绑定地址和端口。停止、失败或切换模式会取消过期的延迟重启任务。后续 build 17 真机反馈已确认监听器能够启动，并推进到配件认证和识别成功；后续完整超时与身份字段试验见上方 build 18/19 调查记录。

## 安装后的首次验证

1. 下载无签名 IPA，用自己的签名方式安装。
2. 在“设置 → 配件身份 → 导入身份文件夹”选择包含三份有效认证材料的文件夹，确认状态变为“已载入并通过本地自检”。这一步只是本地材料检查，还没有证明 iOS 已接受配件。
3. 在“设置 → 连接方式”选择“本机回环（实验）”（build 19 中显示为“仅本机（无需 VPN）”），开启蜂窝数据，先测试 Wi-Fi 开启但未加入网络的情况。
4. 启动 CarPlay，观察是否完成配对、出现持续更新的画面，并实际测试触控。
5. 停止后到系统设置完全关闭 Wi-Fi，再独立重复一次。失败时保留当前模式和停止阶段，不把上一轮成功当作这一轮也成功。

## 默认连接方式：回环，不使用 VPN

默认方案使用 `127.0.0.1` 作为本机端点。iOS 生成的 CarPlay 画面在同一台手机上接收并显示；地图、在线搜索、音乐等应用照常使用系统当前可用的互联网连接。目标环境是蜂窝联网，不把内部视频流发送到公网服务器。

本机 CarPlay 仍需要内部控制、媒体、时间同步以及触控通道。关闭网页共享并不会把这些通道取消。必须同时验证地址通告、监听地址、连接对端和各个动态媒体端口，不能只把界面中的 Wi-Fi 检查去掉。

仅本机模式应具备以下行为，均需结合代码测试与真机验收确认：

- 不强制填写 Wi-Fi 名称和密码，不要求加入路由器或另一台手机热点。
- 不启动供其他设备使用的 HTTP、HTTPS、浏览器 WebSocket 接收页。
- 内部监听限制在指定本机地址，拒绝不属于该模式的连接对端；不能退回 `0.0.0.0` 或 `::` 公开监听来“解决”连接失败。
- 不对外发布用于网页或接收端发现的 Bonjour 服务。
- 保留手机本机显示、触控和原有音频能力；蓝牙输出、Siri、通话和后台行为分别验证。
- 发生失败时保留可定位阶段的诊断信息，不能仅凭 App 显示“正在连接”就视为成功。

蜂窝流量在这里用于在线业务。即使手机能打开网页，也只说明互联网连接正常，不能据此推断本机 CarPlay 的认证、配对或媒体传输已经成功。

## 手动备用实验：LocalDevVPN

只有默认回环路径在目标 iOS 上被系统拒绝、并且需要进一步定位接口限制时，才尝试此备用实验。它不是默认依赖，也不意味着一定需要 VPN 才能使用。

| 参数 | 实验设置 |
| --- | --- |
| 接收端监听地址 | `10.7.1.1` |
| 向系统通告的连接目标 | `10.7.0.1` |
| 外部工具 | 用户手动安装、配置并启用 LocalDevVPN |
| 核心前提 | 工具实际建立了预期虚拟接口和本机包回送路径 |
| 尚待确认 | iOS 私有 CarPlay 服务是否接受此接口、地址与会话 |

这里的两个地址承担不同角色。仅在界面中写入这两个地址，并不会自动创建虚拟网络，也不会自动完成数据包回送。本分支不代替外部工具安装 VPN 描述文件，不自动打开或切换系统 VPN。

实验前先停止 CarPlay，再按 LocalDevVPN 自身说明配置并启用工具，然后在“设置 → 连接方式”选择“LocalDevVPN（实验）”。检查诊断中的监听地址和连接目标是否与上表一致。若出现地址不可绑定、无法建立控制连接或始终没有首帧，应保存诊断并停止该次实验，不扩大监听范围。

**纯蜂窝限制：**LocalDevVPN 维护者在 [issue #31](https://github.com/jkcoxson/LocalDevVPN/issues/31) 中确认过蜂窝模式不可用，并将问题关闭为不计划修复；该报告也包含 Wi-Fi 开启但未关联时失败的反馈。此工具不能被视为已验证的纯蜂窝解决方案。用户本次 App 回送探测成功是有效观察，但探测客户端显式绑定隧道地址，不能证明系统 CarPlay 服务会选择相同接口或允许该传输。

完成备用实验后，停止会话，退出实验方式并关闭该测试 VPN，再回到默认回环方式，避免把两种网络条件混在一次测试里。

**Shadowrocket 的 TUN/代理功能尚未被验证可以提供这里要求的本机包回送。** 能代理互联网请求不代表能完成上述两地址之间的本机重定向。因此不推荐直接照抄地址到 Shadowrocket 盲试，也不将其列为已支持的替代方案。

## 两个独立的准备条件

### Apple 签名：决定能否安装并运行 App

GitHub Actions 只生成 **unsigned IPA**，不使用开发者账号、签名证书或描述文件，不自动发布 Release。下载后需要按你已有的侧载或开发签名方式完成签名、安装以及系统要求的信任/开发者模式设置。

签名后的可用权限也会影响私有 `CoreAccessories` 接口是否能建立本机配件。IPA 能安装不等于私有接口已可用。

### 配件认证身份：决定能否继续建立 CarPlay 会话

上游 [SOURCE-BUILD.md](https://github.com/xmz28/CarWithin/blob/4cdc0f3d0d319bb5fc957932cf1cacf272c02b50/SOURCE-BUILD.md) 明确说明，公开源码不包括配件身份、私钥或证书。公共 CI 产物同样不包括它们。

请自行合法取得并提供你有权使用的配件认证材料，再通过“设置 → 配件身份 → 导入身份文件夹”导入。身份材料包含证书链、叶证书和相应私钥，现有格式为 `certificate.p7b`、`leaf.cer`、`private.x963`。导入前后只核对状态和错误类型，不应在 Issue、日志截图、代码仓库或公开构建产物中贴出文件内容。

如果没有有效身份，预期结果是停在身份准备阶段，不能启动完整 CarPlay。Apple 开发签名证书、用于浏览器 HTTPS 的证书以及本机生成的普通自签证书，不能直接当作配件认证身份使用。

开发者也可使用上游已有的 `Documents/IdentityImport` 和 `--import-mfi-identity` 调试导入路径；材料导入 Keychain 后应清理暂存文件。本分支公共构建脚本会拒绝检测到的身份暂存目录，并再次检查 IPA 中常见身份/签名材料路径，默认不支持把材料打包进公开 IPA。

## 从源码构建

需要安装完整 Xcode 的 Mac。本仓库的核心代码依赖 Apple 的 Security/CommonCrypto 等接口，不能把 Linux 上普通 Swift 编译通过视为完整 iOS 构建。

在仓库根目录执行：

```bash
swift test --configuration release
bash Tools/test_local_network.sh
bash Tools/build_local_ipa.sh
```

构建脚本使用已有 `TDSCarKit.xcodeproj` 的 `TDSCarKit` scheme，构建 `Release`、`iphoneos`、`generic/platform=iOS` 目标，明确关闭代码签名。它不会重新生成工程，也不会自动导入任何身份。

若开发中新增了源文件，应先执行 `python3 Tools/generate_project.py` 更新工程再提交。macOS 的默认生成流程保留已有的个人签名选择；在 Linux 仅生成工程结构时可显式使用 `--fresh`，它跳过读取旧工程，因此不用于保留个人签名配置。生成工程不等于在 Linux 编译了 iOS 应用。

默认输出到 `build/local-ipa/`：

- `CarWithin-Local-unsigned.ipa`：无签名安装包。
- `SHA256SUMS`：IPA 的 SHA-256。
- `build-info.json`：源码提交、Xcode 版本、应用版本和包结构检查结果；真机验证状态固定标为未由 CI 执行。

输出目录可以作为脚本第一个参数指定。默认 Bundle ID 为 `com.evandbg.carwithin.local`；需要自行改为其他 ID 时可设置 `TDS_LOCAL_BUNDLE_IDENTIFIER`。设置签名团队应在个人开发环境处理，不把证书或私钥提交到仓库。

## GitHub Actions

工作流文件为 `.github/workflows/ios-local.yml`。它在 `feature/local-only-cellular` 分支 push 时运行，也支持手动触发。

当前步骤为：

1. 在 `macos-15`、Xcode 16.4 下运行核心 Swift 测试。
2. 运行实际本机 socket 的绑定、回送和对端限制验证。
3. 构建完整 iOS Release App，打包无签名 IPA。
4. 核对包内 Bundle ID、显示名、iPhoneOS 平台和可执行文件，并拒绝常见配件身份与签名文件。
5. 仅在上述步骤成功后上传 IPA、校验值和构建信息，产物保留 14 天。

产物位于该次 Actions 运行的 **Artifacts** 中，不会自动出现在 Releases。手动运行的入口是否可见取决于 GitHub 对默认分支工作流的识别；新建分支后的首次 push 可以直接触发。

工作流不给代码写权限，也不配置 Apple 账号、身份材料或额外 Secrets。用到的第三方 Actions 固定为官方发布提交：

| Action | 固定版本 | 提交 |
| --- | --- | --- |
| [actions/checkout](https://github.com/actions/checkout/releases/tag/v7.0.1) | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [actions/upload-artifact](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |

这些版本、提交和 [macOS 15 runner 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) 在 2026-11-22 查核。将来更新镜像或工具版本时应重新运行验证。

## 真机验收矩阵

测试时记录 iPhone 型号、完整 iOS 版本、App 版本/源码提交、签名方式、身份是否已载入、当前传输模式。下表为待执行的验收，不是已有通过记录。

| 场景 | 操作与观察 | 通过条件 | 当前状态 |
| --- | --- | --- | --- |
| Wi-Fi 开启、未连接 | 在系统设置保持 Wi-Fi 开启，断开所有 Wi-Fi，蜂窝可用；冷启动 App | 无需 SSID/密码即可完成配件认证、配对并出现持续更新的首帧 | 静态核对受同一 `No Network SSID` / `isCarPlay` 门禁阻断；未单独真机复测 |
| Wi-Fi 完全关闭 | 在系统“设置”关闭 Wi-Fi，保持蜂窝可用 | 确认关闭无线接口后仍能建立会话 | iPhone 17 Pro Max，iOS 27.0.1，build 19，5G，接线和拔线两轮均未通过 |
| 地图与在线音乐 | 默认回环模式下查询新地点、请求地图数据、播放未缓存内容 | 在线业务通过蜂窝可用，内部 CarPlay 会话保持；记录系统流量变化 | 待真机验证 |
| 内部通道完整性 | 观察首帧、连续画面、触控、媒体/时间同步建立过程 | 不只控制端口连接成功；画面持续更新，触控有实际响应 | 待真机验证 |
| 启动总期限 | 在前台复现控制 TCP 已连接、或 Pair-Verify/SETUP 已进行但始终没有视频样本提交的故障 | 若未因其他错误提前停止，本机模式约 75 秒后记录最后阶段并停止 | 待真机验证 |
| 首帧判定与实际画面 | 区分只收到编码参数集、视频样本进入显示队列、屏幕真正出现画面这三个状态 | 仅参数集不能结束启动等待；首个视频样本提交显示层后可结束等待，但必须另外观察持续可见的画面，黑屏不能算通过 | 待真机验证 |
| 无对外共享 | 仅为端口测试接入受控 Wi-Fi，保持“仅本机”模式；从另一台授权测试设备检查手机地址 | HTTP 9888、HTTPS 9889 与实际媒体端口不可由其他设备访问；无本 App 接收服务的 Bonjour 广告 | 待真机验证 |
| 模式切换清理 | 停止“原 Wi-Fi 模式”后切到“仅本机（无需 VPN）”，再启动并重复对外端口检查 | 原网页、发现及媒体监听已清理，不残留前一模式的对外共享 | 待真机验证 |
| 扬声器与蓝牙 | 先测扬声器，再连接车机或耳机蓝牙，切换音频输出 | 声音由选定路由输出，持续播放无异常断会话；分别记延迟与断续情况 | 待真机验证 |
| Siri 与通话 | 在停放状态分别触发 Siri、接听/结束通话 | 记录系统音频路由、麦克风和恢复行为，不因音乐可用而默认它们可用 | 待真机验证 |
| 切后台、锁屏 | 多次前后台切换和锁屏/解锁 | 按所选后台策略继续或恢复，画面恢复后触控有效，无持续黑屏 | 待真机验证 |
| 蜂窝变化 | 断开/恢复蜂窝、切换 4G/5G 或信号变弱 | 记录在线业务恢复；内部会话不应因无互联网被主动当作 Wi-Fi 断开而停止 | 待真机验证 |
| 冷启动与重启 | 杀掉 App 后重开；设备重启后解锁再启动 | 身份状态可恢复，端口无占用残留，不靠前一会话遗留状态出画 | 待真机验证 |
| LocalDevVPN 备用 | 按上述独立流程启用后测试，记录 listen/target 两个地址 | 地址可绑定、回送成功且 iOS 接受完整 CarPlay 会话；只收到 TCP 不算完成 | 待真机验证 |
| 长时间运行 | 稳定环境连续运行至少 30 分钟，重复连接/断开 5 次 | 无异常崩溃、失控增长的资源占用或无法恢复的黑屏；记录发热和耗电 | 待真机验证 |

无外部共享的检查要覆盖实际动态端口，不能仅证明 9888 网页打不开。仅在蜂窝模式下从公网扫不到手机，也不能证明 App 没有在本地其他接口监听。

## 诊断顺序

排查时依次记录“身份已载入 → 本机配件已创建 → iAP2 认证/识别 → CarPlay 启动请求 → 控制连接与 Pair-Verify → SETUP/媒体通道 → 视频样本提交显示层 → 屏幕出现持续更新的画面 → 触控/音频”。哪一阶段停止，就先检查该阶段；没有配件身份时，无需把错误归因于蜂窝网络。

两种本机模式都设置了 **75 秒启动总期限**。即使控制 TCP 已连接，或者已经完成 Pair-Verify、进入 SETUP，只要仍没有视频样本真正提交给显示层，这个总期限就继续生效。前台超时会记录最后到达的阶段并停止会话。连接或认证错误可提前结束尝试。

启动等待结束的标志来自 `H264Surface`：首个视频样本实际调用 `display.enqueue(sample)` 后，触发 `onFirstFrameEnqueued`，取消启动总期限并更新界面。只收到 SPS/PPS 等编码参数集、解析到网络包或建立控制连接，都不满足这个条件。日志中的“首个视频帧已送入本机显示层”只证明样本已提交，**不能证明硬件已经解码、画面已呈现或真机验收已通过**。

如果界面已经进入“正在显示 CarPlay”但屏幕仍黑，应继续记录显示层、解码和关键帧诊断，并按实际屏幕判为未通过。首个样本入队后，75 秒启动计时已被取消，它不是用于后续持续黑屏或长时间运行的看门狗。

默认回环失败可以作为接口限制的调查线索，但不能直接断言 iOS 永远不支持无 Wi-Fi。LocalDevVPN 实验成功也只说明该实验配置在那台设备上有效，不能代替默认回环模式的独立验收。
