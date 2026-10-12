# MobileBlack — iOS 骚扰电话名单拦截

自用的 iOS 来电拦截 App。基于系统 **CallKit Call Directory Extension**：
名单里的号码，「拦截」级直接静音拦掉，「标记」级只在来电界面挂个标签、仍会振铃。

起因是 400 开头的推销电话太多。但先说清楚一件事——

## 硬约束（决定了这东西能做什么、不能做什么）

以下各条皆核自 Xcode 27 SDK 头文件与 Apple 官方文档，非臆测：

1. **不支持号段通配。** `CXCallDirectoryExtensionContext` 只有
   `addBlockingEntryWithNextSequentialPhoneNumber:`，一次一个完整号码，没有前缀／范围接口。
   400 后八位有一亿种组合，枚举不可能。**所以「400 整段拦掉」在 iOS 上做不到**，
   那部分请交给运营商：移动发短信 `KTFSR` 到 `10086`（取消 `QXFSR`），
   电信 `KTFSR` 到 `10001`，联通走「联通助理」公众号的手机管家。
2. **号码必须按数值严格升序喂入**，乱序整批失败（`EntriesOutOfOrder`），
   重复亦失败（`DuplicateEntries`），条数超限失败（`MaximumEntriesExceeded`）。
3. **号码类型是 `int64_t`。** Xcode 27 SDK 里 `typedef int64_t CXCallDirectoryPhoneNumber`
   （旧 SDK 为 `NSString`），故名单内部一律以整数存储、排序。
4. **读不到通话记录。** iOS 不允许 App 读最近通话，故「接完自动入黑名单」做不到，
   必须手动加或导入。
5. **短号拒收。** 95588、10086 之类，系统未必按「86 + 短号」形式比对，
   写了也拦不住还易误伤，故规范化时一律拒绝（国内部分少于 7 位即拒）。
6. **出厂名单为空**（只有一条标注为示例的标记级号码）。默认不拦任何东西，
   免得误伤快递、外卖、银行、医院。

## 目录结构

```
MobileBlack.xcodeproj        工程文件（手写，objectVersion 77 + 同步组，无第三方生成工具）
MobileBlack/                 主 App（SwiftUI）：名单管理、导入、重载扩展、跳系统设置
CallDirectoryExt/            Call Directory 扩展（.appex）：把名单喂给系统
Shared/                      两端共用的纯逻辑，不 import CallKit，故 Mac 上可直接 swift test
  NumberNormalizer.swift     号码规范化（各种写法 → Int64）
  ListTextParser.swift       名单文本解析
  BlockEntry.swift           名单条目模型（含 block／label 两级）
  BlacklistStore.swift       名单存取（App Group 容器 + JSON）
  LoadLog.swift              扩展加载结果落盘，供主 App 显示
  CallDirectoryErrorExplainer.swift  失败码译成中文
  Bundle+Seed.swift          找内置种子名单
  blocklist.seed.txt         出厂名单（可编辑）
Config/                      两个 target 的 entitlements（App Group）
Tests/                       SwiftPM 单元测试（Mac 上跑，不需模拟器）
tools/normalize.py           把杂乱名单规范化成可导入格式
tools/test_normalize.py      上述工具的单元测试
```

`Shared/` 同时被 Xcode 工程（两个 target 各编一份）与 SwiftPM（跑测试）使用，
一份代码两处用，规则不会走岔。

## 当前状态：卡在签名，须你手动一次

代码已通：**模拟器编译零错误零警告**，30 条 Swift 测试 + 15 条 Python 测试全绿。

但**真机编译失败**，原因不在代码：

```
error: No Accounts: Add a new account in Accounts settings.
error: Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the App Groups capability.
```

本机 Xcode **未登录任何 Apple ID**（`DVTDeveloperAccountManagerAppleIDLists` 为空），
命令行无从注册新的 App ID 与 App Group，只能退回不含 App Groups 的通配描述文件。

**解法**（约一分钟，只需做一次）：

1. 打开 Xcode → `Settings` → `Accounts` → 左下 `+` → 登录你的 Apple ID（Team 为 `Fabao Yi`，ID `VM9PQBV9TZ`）。
2. 双击 `MobileBlack.xcodeproj` 打开工程。
3. 选中 `MobileBlack` target → `Signing & Capabilities`，确认 Team 是 Fabao Yi；
   `CallDirectoryExt` target 同样确认一遍。
   Xcode 会自动注册 `com.fabaoyi.mobileblack`、`com.fabaoyi.mobileblack.calldirectory`
   与 App Group `group.com.fabaoyi.mobileblack`，并生成描述文件。
4. 插上 iPhone（iOS 26.6.1，需在设备上信任本机），选中真机按 ⌘R 安装。

此后命令行也能编译：

```bash
xcodebuild -project MobileBlack.xcodeproj -scheme MobileBlack \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```

## 不登录 Xcode 也能装机（验证版，2026-10-12 已实测走通）

若一时不便登录账号，可借用 Team 里那张**通配描述文件**（`iOS Team Provisioning Profile: *`，
不含 App Groups，但含本机设备 UDID）装一个「无 App Group」的验证版，
专测 Call Directory 在真机上是否工作。代价：主 App 写的名单扩展读不到，
扩展只吃内置种子；界面上会有一条 App Group 不可用的警告，属预期。

```bash
# 1. 编出不签名的产物。
#    ENABLE_DEBUG_DYLIB=NO 必不可少：Debug 构建会生成 MobileBlack.debug.dylib，
#    主二进制经 @rpath 加载它，而手工 codesign 不会签这枚散置的 dylib，
#    dyld 拒载未签名之物，装上一启即闪退（实测踩过）。
xcodebuild -project MobileBlack.xcodeproj -scheme MobileBlack -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO build

APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/MobileBlack-*/Build/Products/Debug-iphoneos/MobileBlack.app | head -1)
PP="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/<通配描述文件UUID>.mobileprovision"
IDENT=<与描述文件内证书指纹相合的钥匙串身份SHA1>

# 2. 嵌描述文件。手工签名不补 application-identifier，安装必报
#    "missing the application-identifier entitlement"，故主 App 与扩展各用一枚权限文件
cp "$PP" "$APP/PlugIns/CallDirectoryExt.appex/embedded.mobileprovision"
cp "$PP" "$APP/embedded.mobileprovision"
codesign -f -s "$IDENT" --entitlements Config/ManualExt.entitlements --timestamp=none "$APP/PlugIns/CallDirectoryExt.appex"
codesign -f -s "$IDENT" --entitlements Config/ManualApp.entitlements --timestamp=none "$APP"

# 3. 装机并启动
xcrun devicectl device install app --device <设备UDID> "$APP"
xcrun devicectl device process launch --device <设备UDID> com.fabaoyi.mobileblack
```

三个坑，皆实测所得：

1. 通配描述文件是 **Xcode 托管**的，`CODE_SIGN_STYLE=Manual` 直接用它会被拒
   （"is Xcode managed, but signing settings require a manually managed profile"），
   故须走「不签名构建 + codesign 亲手签」这条路。
2. 签名证书必须与描述文件内 `DeveloperCertificates` 的指纹相合，否则装机报证书不符；
   用 `openssl x509 -fingerprint -sha1` 与 `security find-identity -v -p codesigning` 比对。
3. `application-identifier`  entitlement 须明写，且主 App 与扩展各写各的 bundle id
   （见 `Config/ManualApp.entitlements`、`Config/ManualExt.entitlements`）。
4. **Debug 的调试 dylib 必须关掉**（`ENABLE_DEBUG_DYLIB=NO`）。否则包内多一枚
   `MobileBlack.debug.dylib`，手工签名不签它，真机一启即闪退；
   死因可用 `codesign -dv <app>/MobileBlack.debug.dylib` 验之（报 not signed at all）。

## 装好之后必须做的一步

系统不会自动启用扩展，须手动开启，否则名单一条都不生效：

`Settings` → `Apps` → `Phone` → `Call Filtering`（旧版叫 Block & Identification）→ 打开 **MobileBlack**。

App 首屏的状态卡会直接显示「已启用／未启用」，未启用时给一个「去开启」按钮直达该页。

## 怎么用

- **加一个号码**：右上 `＋`，输入号码（写法随意：`4008208820`、`+86 400-820-8820`、`(010) 1234 5678` 都认），
  选级别，存。界面会即时显示规范化后的号码，避免存进去的和想拦的不是同一个号。
  也可以点「从通讯录选择」直接从联系人里挑一个号码加入。
- **批量导入**：左上「导入」，粘贴文本或选 `.txt`／`.csv` 文件。
- **改名单文件**：编辑 `Shared/blocklist.seed.txt` 后重新编译；
  或用工具把杂乱名单先洗干净：

```bash
python3 tools/normalize.py 我的名单.txt -o Shared/blocklist.seed.txt
python3 tools/normalize.py 我的名单.txt --level label --check   # 只看结果不写文件
```

名单格式：每行一条 `号码[,级别][,标签][,备注]`，级别 `block`（拦截，默认）或 `label`（标记），
`#` 开头为注释，备注里可含逗号。

任何改动都会**自动存盘并触发扩展重载**，不必手动干预。

## 怎么验证真的拦住了

出厂名单是空的，不会拦任何号码。验证办法：

1. 把**自己的另一个号码**（或家人号码）加为 `block` 级；
2. 用它拨打本机 —— 应当直接被拦，通话记录里显示为已阻止的来电；
3. App 首屏状态卡的「上次加载」一行会显示成功与否、拦截与标记各多少条。

若加载失败，状态卡会显示译成中文的原因（如「扩展被停用」「名单条数超出系统上限」），
不必去猜。

## 测试

```bash
swift test                                   # 30 条，覆盖规范化、解析、存取、失败码翻译
python3 -m unittest discover -s tools -t tools   # 15 条，覆盖 tools/normalize.py
```

测试跑在 Mac 上，不需模拟器、不需签名。`tools/normalize.py` 的规则与
`Shared/NumberNormalizer.swift` 一一对应，改一边必须改另一边，两边的测试用例也成对存在。

## 未验之处（如实记下）

1. **真机未验。** 签名卡在账号登录，故「Int64 号码在 iOS 26.6.1 运行时是否被正确识别」
   尚未实测。SDK 27 把 `CXCallDirectoryPhoneNumber` 定义为 `int64_t`，
   若该变更始于 iOS 27 运行时，则 iOS 26.6.1 上可能失败。
   真机装上后看状态卡「上次加载」一行即知：成功则显示条数，失败则显示中文原因。
   我原想用本机的 iOS 26 模拟器运行时核对其 CallKit 二进制，
   但该二进制在 dyld 共享缓存内，两轮探查未取到，故留待真机实测。
2. **扩展内存上限未知。** Apple 只给了 `MaximumEntriesExceeded` 与 `LoadingInterrupted`
   两个失败码，没公开条数与内存上限。代码里自设 50,000 条的闸，超限即拒并计数，
   真实上限待大名单实测。
3. **App 图标缺失。** `AppIcon.appiconset` 里只有空的 Contents.json，
   装上后是系统默认的白底图标。
4. **未做上架准备。** 自用而已，未做 App Store 审核所需的隐私说明、截图等。

## 后续可做的

- v2：增量加载（`isIncremental` ＋ `removeBlockingEntry`），名单大时省时间
- v3：号码来源——接一个可查号码标记的公开数据源，或从运营商公众号导出的举报记录批量导入
- 图标：画一个（黑底盾牌之类）
