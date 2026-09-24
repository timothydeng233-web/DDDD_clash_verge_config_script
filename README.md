# Clash Verge Rev Codex 本机适配工具

本项目是一套供 Codex 审计并按目标 Windows 电脑实际情况生成配置的模板，不是可以在所有电脑上原样覆盖的固定配置包。

> [!WARNING]
> 禁止未经审计直接部署。每台电脑的安装目录、配置目录、订阅策略组、WSL 网络模式、出口 MTU 和现有配置都可能不同。脚本默认仅执行只读 `Audit`。

## 功能

- 从进程、注册表、WinGet、Scoop 和常见目录动态检测 Clash Verge Rev。
- 使用当前官方 WinGet ID 安装客户端，但只有显式传入 `-InstallIfMissing` 才会安装。
- 自动读取最终生成的 `clash-verge.yaml`，识别本机订阅策略组。
- 基于本机现有 `verge.yaml` 修改少量必要字段，不覆盖主题、快捷键、日志等个人设置。
- 根据真实策略组生成通用 `Merge.yaml` 和仅对目标订阅生效的 `Script.js`。
- 统一生成 OpenAI、ChatGPT、Codex 登录、静态资源、身份认证和 WebSocket 相关规则。
- 支持 Gemini、Google AI Studio、Gemini API、Google 登录和 Code Assist。
- 支持 Microsoft Store、微软账号、Office、OneDrive、Teams、Edge 和 Windows Update 关键链路。
- 为 ScienceDirect PDF、`sciencedirectassets.com` 与 Elsevier 辅助 CDN 提供优先直连规则，减少校园 VPN 与海外代理出口混用。
- Microsoft 控制链路与大型下载链路可以分别选择出口；两者默认 `DIRECT`。
- 审计 OpenAI、Gemini 和 Microsoft 域名是否使用预期策略组。
- 检查 Microsoft Store 应用包、许可证/安装/更新服务、WinHTTP 代理、Chrome 与 Clash 端口。
- 可运行不带账号和密钥的 OpenAI、Gemini、Microsoft 和学术网站公共端点测试。
- 只读审计 Chrome 原生 PDF 设置、Adobe Acrobat 扩展及相关企业策略，辅助区分浏览器扩展故障和网络故障。
- 提供 `IsolatedTest`：先在系统临时目录生成、检查并由 Mihomo 校验配置，再执行连通测试，全程对比本机运行配置哈希且不部署。
- 提供 PowerShell `Auto`（TUN）、`Session` 和显式 `Persistent` 代理模式。
- 可选启用 TUN、设置经过确认的 MTU 或阻断 QUIC。
- 支持先生成本机文件而不部署；每次正式部署前创建独立时间戳快照，失败时自动回滚。
- 恢复时既能还原原文件，也能删除部署前不存在、由部署创建的文件。

## 文件结构

```text
.
├── ConfigBackup
│   ├── Merge.yaml                 # 不含本机域名和特定代理组的通用模板
│   ├── Script.js.template         # 带订阅名称守卫的分流模板
│   ├── Merge.local.example.yaml   # 私有规则示例
│   ├── Academic.domains.txt       # 学术 PDF/CDN 最小域名清单
│   ├── Gemini.domains.txt         # Gemini/Google AI 域名规则定义
│   ├── Microsoft.domains.txt      # 微软登录、商店控制面和应用服务
│   ├── Microsoft.Download.domains.txt # 商店、系统更新和大型下载
│   ├── OpenAI.domains.txt         # OpenAI/ChatGPT/Codex 域名规则定义
│   └── verge.yaml                 # GUI 顶层字段变更说明
├── docs
│   └── 本机配置优化建议.md          # 当前电脑建议，仅供参考，不自动执行
├── Deploy-ClashVerge.ps1          # Audit / Deploy / Restore 主脚本
├── Set-PowerShellProxy.ps1         # PowerShell 会话/用户级代理助手
├── tests/Validate-Portable.ps1     # 临时沙箱、Mihomo 和订阅隔离验证
├── tools/clash-route-inspector/    # 只读网址路由检查器
├── 双击一键统一部署.bat             # 实际只启动只读审计
├── 双击一键还原配置.bat             # 恢复最近一次部署快照
└── .gitignore                     # 排除本机配置和隐私数据
```

真实订阅、节点、私有域名、本机生成配置和部署快照不得提交到 GitHub。

## 在另一台 Windows 电脑使用

1. 从 GitHub 克隆仓库。先安装并启动一次 Clash Verge Rev，导入该电脑自己的订阅。Windows 10 建议使用 22H2；脚本兼容 Windows PowerShell 5.1。仅自动安装功能需要 WinGet（Windows 10 1809 或更新版本）。
2. 在仓库目录运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Deploy-ClashVerge.ps1 -Action Audit`，核对客户端路径、配置目录、订阅名称和真实策略组。
3. 以该电脑的实际订阅名称和策略组运行 `-Action IsolatedTest -TargetSubscription "订阅名称" -ProxyGroup "真实策略组"`。若要指定 Gemini 或微软出口，也必须使用该订阅真实存在的组名。
4. 确认隔离检查通过后，用 `-Action Generate` 查看生成在被 Git 忽略的 `LocalConfig/` 中的 `Merge.yaml`、`Script.js` 和 `verge.yaml`。需要部署时再按下文使用 `-Action Deploy`。
5. 在客户端中检查目标订阅是否绑定生成的全局 Merge 和 Script 扩展，并刷新订阅。脚本的 `profileName` 必须与 `-TargetSubscription` 一致，否则它会原样返回配置。其他订阅不注入目标订阅的分流规则；全局 Merge 的通用设置仍会作用于绑定它的订阅。

本机专用域名和私有规则应仅保存在目标电脑，不要加入公开模板。仓库不包含订阅链接或节点，因此另一台电脑仍需自行导入订阅。

## 使用方法

### 1. 只读审计（默认）

```powershell
.\Deploy-ClashVerge.ps1
# 等价于：
.\Deploy-ClashVerge.ps1 -Action Audit
```

审计会显示检测到的程序路径、Mihomo 路径、配置目录、策略组和 Merge 绑定状态，不修改文件。

如需同时测试 OpenAI、Gemini 和 Microsoft Store 公共端点：

```powershell
.\Deploy-ClashVerge.ps1 -Action Test
```

该测试不读取账号或 API Key，只检查 TLS、HTTP 响应和连接耗时。HTTP 401、403 或 404 仍可能表示网络连接成功，应结合脚本输出判断。

修改项目模板或准备部署前，应优先运行临时隔离测试：

```powershell
.\Deploy-ClashVerge.ps1 -Action IsolatedTest -ProxyGroup "🔰 选择节点"
```

该操作在系统临时目录生成配置，拒绝可能覆盖订阅节点的顶层 `proxies`、`proxy-providers`、`proxy-groups` 或 `rules`，检查未替换占位符，调用 Mihomo 校验 Merge，并确认测试前后本机运行配置哈希一致。临时文件会自动删除。仓库附带的 `tests/Validate-Portable.ps1` 还会使用模拟订阅验证生成脚本的隔离行为，并让 Mihomo 校验生成的目标规则；该额外测试需要 Node.js。

PowerShell 默认依赖 TUN。个别工具需要显式代理时，只为当前终端启用：

```powershell
. .\Set-PowerShellProxy.ps1 -Action Enable
. .\Set-PowerShellProxy.ps1 -Action Disable
```

自定义安装或配置目录可以显式传入：

```powershell
.\Deploy-ClashVerge.ps1 -Action Audit `
  -InstallPath "D:\Apps\Clash Verge\clash-verge.exe" `
  -ConfigDir "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
```

### 2. 经 Codex 确认后部署

可以先生成并校验到被 Git 忽略的 `LocalConfig`，完全不修改 Clash Verge：

```powershell
.\Deploy-ClashVerge.ps1 -Action Generate -ProxyGroup "🔰 选择节点"
```

默认行为是 Gemini 复用主策略组，微软账号、商店、应用服务和大型下载均使用 `DIRECT`：

```powershell
.\Deploy-ClashVerge.ps1 -Action Generate `
  -ProxyGroup "🔰 选择节点" `
  -GeminiGroup "✨ Gemini" `
  -AcademicGroup DIRECT `
  -MicrosoftGroup DIRECT `
  -MicrosoftDownloadGroup DIRECT
```

只有目标网络无法直连微软下载端点时，才把 `-MicrosoftDownloadGroup` 改为真实存在的代理组。大型商店应用和系统更新会消耗较多代理流量。

确认生成结果后再部署：

保留本机 TUN 和 MTU，仅部署基础规则：

```powershell
.\Deploy-ClashVerge.ps1 -Action Deploy -ProxyGroup "🔰 选择节点"
```

明确启用 TUN，并在确认路径 MTU 后设置 1500：

```powershell
.\Deploy-ClashVerge.ps1 -Action Deploy `
  -ProxyGroup "🔰 选择节点" `
  -TunMode Enable `
  -TunMtu 1500
```

需要阻断 UDP/443（包括 QUIC）时才使用：

```powershell
.\Deploy-ClashVerge.ps1 -Action Deploy `
  -ProxyGroup "🔰 选择节点" `
  -BlockQuic Enable
```

未安装客户端时允许脚本通过 WinGet 安装：

```powershell
.\Deploy-ClashVerge.ps1 -Action Deploy -InstallIfMissing
```

请在 Clash Verge Rev 中核对目标订阅的 `Merge` 和 `Script` 扩展绑定，然后刷新订阅。部署脚本写入扩展文件，不自动更改订阅绑定关系。

### 3. 恢复

```powershell
.\Deploy-ClashVerge.ps1 -Action Restore
```

快照保存在目标配置目录的 `codex-deployment-backups` 中，不在 Git 仓库内。恢复默认选择最新快照。

## 参数

| 参数 | 含义 |
|---|---|
| `-Action Audit` | 只读检测，默认行为 |
| `-Action Test` | 只读审计并测试 OpenAI、Gemini、Microsoft 和学术网站公共端点 |
| `-Action IsolatedTest` | 在临时目录生成并校验配置、执行连通测试，不部署或重载客户端 |
| `-Action Generate` | 生成并验证到 `LocalConfig`，不部署 |
| `-Action Deploy` | 生成、验证并部署本机适配配置 |
| `-Action Restore` | 恢复最近一次部署快照 |
| `-InstallPath` | 显式指定 `clash-verge.exe` |
| `-ConfigDir` | 显式指定用户配置目录 |
| `-SnapshotPath` | `Restore` 时指定要恢复的精确快照；省略则恢复最新快照 |
| `-TargetSubscription` | 指定分流规则匹配的订阅名称（默认 `ikuuu`）；在其他电脑应显式传入实际名称 |
| `-ProxyGroup` | 指定订阅中真实存在的策略组 |
| `-GeminiGroup` | Gemini 策略组；省略时复用主策略组 |
| `-AcademicGroup` | ScienceDirect PDF/Elsevier CDN 出口，默认 `DIRECT`；可指定本机真实存在的校园策略组 |
| `-MicrosoftGroup` | 微软登录、商店控制面和应用服务出口，默认 `DIRECT` |
| `-MicrosoftDownloadGroup` | 商店/Windows Update 下载出口，默认 `DIRECT` |
| `-OutputDirectory` | 指定 `Generate` 输出目录 |
| `-TunMode Auto/Enable/Disable` | 保留、启用或禁用 TUN |
| `-TunMtu 0..9000` | `0` 表示不覆盖；其他值必须经过本机检测 |
| `-MixedPort 0..65535` | `0` 保留本机端口；非零值才显式覆盖 |
| `-BlockQuic Auto/Enable/Disable` | 默认不增加阻断规则；`Enable` 阻断 UDP/443 |
| `-InstallIfMissing` | 找不到客户端时允许 WinGet 安装 |
| `-SkipOpenAiRules` | 生成时不加入项目维护的 OpenAI 域名规则 |
| `-SkipGeminiRules` | 生成时不加入 Gemini 域名规则 |
| `-SkipAcademicRules` | 生成时不加入项目维护的学术 PDF/CDN 规则 |
| `-SkipMicrosoftRules` | 生成时不加入微软控制与下载规则 |

## Codex 执行规范

将下面的提示词提供给目标电脑上的 Codex：

```markdown
请审计此 Clash Verge Rev 配置模板，并根据本机实际环境完成适配。

必须遵守：

1. 首先运行 `Deploy-ClashVerge.ps1 -Action Audit`，只读检查程序、配置、Mihomo、策略组、OpenAI/Gemini/Microsoft 路由、Microsoft Store 服务和 Merge 绑定状态。
2. 修改模板、测试新规则或准备部署前，必须优先运行 `-Action IsolatedTest`。只有隔离生成、Mihomo 校验、危险顶层字段检查和本机配置哈希检查全部通过，才能考虑部署。单纯排查现有网络时可运行只读 `-Action Test`。
3. 不得假设安装在 C 盘。自动检测失败时，根据本机注册表和正在运行的进程确定路径，再通过 `-InstallPath` 或 `-ConfigDir` 显式传入。
4. 检查仓库中不存在订阅 URL、节点、Token、密码、API Key、私有物理路径和不应公开的域名。发现隐私数据时停止部署。
5. 从本机最终生成的 `clash-verge.yaml` 获取 `proxy-groups[].name`。部署前必须保证 Merge 中每个规则目标都真实存在；无法唯一判断时询问用户，不得猜测。
6. 默认保留本机 TUN、MTU 和 QUIC 行为。只有用户明确要求，或检测结果能够证明有必要时，才传入 `-TunMode Enable`、`-TunMtu` 或 `-BlockQuic Enable`。
7. 设置 MTU 前检查 Windows 出口网卡、TUN 网卡、WSL 网络模式和实际路径 MTU。不得把 1500 当成所有电脑的固定值。
8. 不要把整个浏览器、PowerShell、VS Code、Codex、WebView2 或 Microsoft Store 进程强制代理。本地回环和私有网段应使用目标地址直连规则。
9. 部署必须通过 `-Action Deploy` 执行，让脚本再次在临时目录完成隔离预检，再创建时间戳快照、安装文件并在失败时回滚。不要绕过快照直接覆盖 AppData 文件。
10. 部署后确认 Clash Verge Rev 保持运行，并提醒用户核对目标订阅的 `Merge`、`Script` 扩展绑定后刷新。
11. 不得把目标电脑生成的配置、快照、订阅或私有规则提交到 GitHub。
12. `ConfigBackup/*.domains.txt` 是各服务网络依赖的规则来源；更新时必须重新执行 Audit、IsolatedTest 和 Test。
13. 校外访问 ScienceDirect 时，正文和机构认证可继续由 EasyConnect 接管；PDF 与 Elsevier CDN 默认 `DIRECT`，也可用 `-AcademicGroup` 指向目标电脑真实存在的校园策略组，但不得猜测组名。实际 PDF 成功率仍需在已登录浏览器中低频验证，避免连续刷新触发风控。
14. ScienceDirect 出现“未能加载 PDF”时，先比较普通窗口、无痕窗口和临时停用 Adobe Acrobat 扩展后的结果。不得在没有 A/B 证据时先改 MTU、TUN、DNS 或 QUIC，也不得记录带 `X-Amz-*` 参数的签名 PDF 地址。
15. Microsoft Store/Windows Update 下载默认 `DIRECT`。除非本机测试证明直连失败，不要让大型下载占用代理节点。
```

## 设计说明

- `profile.block-quic` 不是 Mihomo 通用配置项，因此已经移除。可选 QUIC 阻断通过明确的 UDP/443 规则完成。
- `dns.listen` 不再强制设置为 `0.0.0.0:53`，避免无必要的局域网监听和端口冲突。
- MTU 默认不覆盖。`mixed` TUN 栈保留为模板建议，但仍应由 Codex 根据目标机器检查。
- 默认规则不包含任何作者私有域名。私有规则可写入被 `.gitignore` 排除的 `*.local.yaml`，由 Codex 在目标电脑审计后处理。
- OpenAI 域名规则从独立清单生成，避免模板、审计逻辑和建议文档各自维护不同版本。
- Microsoft 官方说明 Store/Windows Update 依赖账号认证、许可证、目录、更新与 Delivery Optimization 多组端点，因此项目将控制链路和下载链路分开管理：[Windows 11 端点](https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints)、[Delivery Optimization](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-faq)。
- 下载规则支持 TCP 80/443 的域名分流；不代理局域网 P2P 端口 7680，也不改变 Delivery Optimization 或 Windows Update 服务配置。
