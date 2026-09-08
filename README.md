# F.I.R.E · 自由进度

一个本地优先的 iPhone 财务自由进度 App，用账单和资产快照回答：现在完成了多少、离目标还差多少钱、最近一个月前进了多少。

SwiftUI · SwiftData · iOS 17+ · macOS 14+ · MIT

## 能做什么

- 导入咔皮导出的 `.xlsx`，按导出日期区间预览差异、确认同步，并支持撤回最近一次同步。
- 根据历史账单估计日常和不规则支出；月度收支、年度收支均可手动调整，保留历史参考。
- 管理基金、股票、现金、负债及月度完整资产快照；截图先经设备端 Vision OCR，可通过 Mac 上的 Codex 辅助整理。
- 展示 FIRE 目标、差额和预计时间；查看月度净资产变化及进度历史，历史进度按当前目标统一重算。
- 从 ECB 参考汇率换算外币，保留快照时采用的汇率；提供通胀和国债收益率的联网规划参考。
- 一键隐藏财务数字、设备认证锁和同设备加密备份。
- 可选的 Mac 菜单栏桥接：使用本人 ChatGPT 登录的 Codex 生成月报、解释大额支出和类别异动，并继续追问。

账单、资产和 FIRE 计算可在 iPhone 本地使用。AI 功能需要同一局域网中的 Mac 在线运行 F.I.R.E Bridge，并具有可用的 Codex 登录和额度；不会回退到按量计费的 Platform API。

当前提供源码自行构建，未发布 App Store / TestFlight 安装包。CloudKit 同步、Tailscale 远程桥接尚未实现。截图识别和外部服务可能失败，保存资产前需核对产品、币种和市值。

## 从零构建

准备 macOS、**Xcode 26+（含 iOS 26 SDK）**和 XcodeGen。运行系统最低为 iOS 17 / macOS 14；新后台任务能力使用 iOS 26 API，因此构建需要新 SDK。Swift 包使用 Swift 6。发布检查使用 Xcode 26.6 和 XcodeGen 2.46.0。

```bash
git clone https://github.com/swaydong/fire-freedom.git
cd fire-freedom
brew install xcodegen
./Scripts/generate-project.sh
open FIREFreedom.xcodeproj
```

先选择 `FIRE` scheme 和 iPhone Simulator 运行；模拟器构建不需要 Apple 开发者账号。账单导入和计算也不要求安装 Codex。

真机安装：把 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填写自己的 Team ID 和唯一 Bundle ID。该文件已被 Git 忽略。然后在 Xcode 中登录 Apple 账号，选择已连接、解锁并启用开发者模式的 iPhone 运行 `FIRE`。普通 Apple ID 的免费签名会过期，届时需要重新签名安装。

### 可选：连接 Codex

1. 在 Mac 安装 Codex CLI，用自己的 ChatGPT 账号登录；`codex login status` 应明确显示 ChatGPT 登录。
2. 构建并运行 `FIREBridge` scheme。桥接是菜单栏 App；它会注册登录启动，并在运行时使用局域网发现和已配对连接。
3. 在菜单栏打开配对，在 iPhone 的“设置”顶部连接 Mac。核对双方显示的六位短码后确认。
4. 在“分析”中选择月份并生成报告，或在资产截图识别时使用桥接辅助。

桥接使用 stdio 启动 Codex App Server；局域网只有受认证、加密保护的业务协议。Codex 的 Web 搜索和通用工具被禁用。证券身份与汇率由受限的独立网络客户端查询。

公开版内置产品候选库为空，不携带个人化产品清单或 HKEX 补丁。OpenFIGI 等在线校验和可注入的本地目录接口仍可使用；离线无候选时需人工确认。AKShare 是可选外部依赖。

## 第一次使用

1. 在“收支”中导入咔皮账单，检查覆盖日期、差异和疑似重复，再确认同步。
2. 在“资产”中展开填写，添加截图或手动录入资产、现金和负债，核对后保存完整快照。
3. 在首页参考历史数据，确认月度结余、年度奖金结余及月度/年度支出规划。
4. 以后每月保存完整快照，即可查看净资产增减和 FIRE 进度变化。净资产变化包括投入、取出、行情、汇率和负债变化，不等于投资收益。

提取率在设置中调整，默认 3.5%；目标金额为当前年度支出除以提取率。预计时间依赖规划参数，是情景计算，不能保证未来达成日期。

## 验证

```bash
# 生成工程、Swift 包测试、iOS 模拟器测试及两个 App 构建
./Scripts/verify.sh

# 仅运行 Swift 包构建及测试
./Scripts/verify.sh --core-only
```

完整检查需要在 Xcode 中安装可用的 iPhone Simulator，缺少运行环境会明确失败。公开测试使用合成样本，不包含真实账单和资产截图。可选的 `FIRE_KAPI_FIXTURE` 仅从本机路径读取本人提供的账单，执行通用导入校验；请勿提交此文件或含真实内容的测试日志。

## 工程和文档

```text
Apps/FIREiOS/             iPhone 应用与本地存储
Apps/FIREBridge/          Mac 菜单栏桥接
Sources/FIRECore/         账单导入、财务计算、月度进度
Sources/FIREBridgeKit/    Codex、证券校验与加密配对
Tests/                   Swift 包测试
Apps/FIREiOSTests/        iOS 集成测试
Config/                  可移植构建与本地签名配置
```

- [计算和数据口径](Docs/ARCHITECTURE.md)
- [隐私与桥接安全边界](Docs/SECURITY.md)
- [验收范围和限制](Docs/ACCEPTANCE.md)
- [贡献说明](CONTRIBUTING.md) · [漏洞报告](.github/SECURITY.md)
- [MIT License](LICENSE) · [第三方许可及数据来源](THIRD_PARTY_NOTICES.md)

这是个人财务规划工具，不构成投资建议。项目与咔皮、OpenAI/Codex、Bloomberg/OpenFIGI 及相关券商、基金平台无隶属或背书关系。请勿在公开 Issue、PR 或截图中上传账单、真实持仓、账号、配对凭据和备份。
