# Clash Verge Rev 多端配置一键同步工具

本工具用于实现多台 Windows 电脑上 **Clash Verge Rev** 客户端配置的快速统一部署与分流规则同步。本同步包不包含任何具体的订阅链接和节点数据，支持在不同机器上安全分发。

---

## 🛠️ 功能与核心作用

1. **软件自动检测与静默安装**：自动检测本机是否安装 Clash Verge Rev。若未安装，将调用 Windows 包管理器 `winget` 自动下载并静默完成官方安装。
2. **强制启用 TUN 模式**：通过配置统一，确保客户端强制开启 TUN 模式，实现在网络层对系统全局流量（包括 WSL2 内部流量）的透明代理。
3. **关闭系统代理**：关闭系统代理（System Proxy），避免本地回环流量（如 gRPC、WebSocket 等进程间高频本地通信）误入代理导致卡死。
4. **锁定网络端口**：锁定网络混合端口为 `7897`，保持多台电脑命令行及 API 端口一致。
5. **锁定 Meta/Mihomo 内核**：统一指定使用 mihomo 内核，保证高级规则与网卡参数的最大兼容性。
6. **锁定 TUN 网卡 MTU**：锁定虚拟网卡 MTU 为 `1500`，彻底解决 WSL2 在镜像模式（`mirrored`）下因 MTU 巨型帧不匹配导致 HTTPS 握手包被物理网卡丢弃的问题。
7. **优化 DNS Fake-IP 过滤**：瘦身 `fake-ip-filter`，排除 `localhost`、`127.0.0.1` 环回流量被代理污染，同时移除了大量海外域名，彻底规避国内 DNS 污染，提升网络握手成功率与速度。

---

## 📂 文件结构与内容说明

```text
ClashVergeSync/
├── ConfigBackup/
│   ├── verge.yaml          # 已脱敏的系统全局运行配置
│   └── Merge.yaml          # 优化的全局覆写分流规则与 DNS/TUN 参数
├── Deploy-ClashVerge.ps1   # 核心部署与同步 PowerShell 脚本
├── 双击一键统一部署.bat      # 管理员提权引导批处理
└── README.md               # 本说明文档
```

### 1. `Deploy-ClashVerge.ps1` (PowerShell 部署脚本)
* **执行逻辑**：
  * 检测当前进程是否拥有管理员权限，若无则尝试提权重新拉起。
  * 扫描系统常用安装路径，若未检测到 `clash-verge.exe`，则调用 `winget` 静默安装。
  * 自动在当前用户的 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\` 路径下建立配置备份（原配置增加 `.bak` 后缀）。
  * 将 `ConfigBackup/` 目录中的 `verge.yaml` 和 `Merge.yaml` 安全拷贝到 Clash 配置文件目录。
  * 强杀旧的 `Clash Verge` 进程并自动重新拉起客户端以重载配置。

### 2. `双击一键统一部署.bat` (批处理启动器)
* **执行逻辑**：
  * 自动切换当前工作目录，调用 PowerShell 以管理员权限及 `-ExecutionPolicy Bypass` 策略运行 `Deploy-ClashVerge.ps1` 核心脚本，免去手动调整系统执行策略的繁琐步骤。

### 3. `ConfigBackup/verge.yaml` (系统级配置)
* **核心内容**：
  * 锁定 `enable_tun_mode: true`、`enable_system_proxy: false`、`verge_mixed_port: 7897`。

### 4. `ConfigBackup/Merge.yaml` (全局覆写规则)
* **核心内容**：
  * **规则层 (`prepend-rules`)**：将 Google 核心认证与 Token 刷新域名（如 `accounts.google.com`、`oauth2.googleapis.com` 等）正确配置为走代理；前置拦截并加速配置 GitHub Copilot、OpenAI ChatGPT 域名。
  * **网卡层 (`tun`)**：配置全局生效的 `stack: mixed` 并锁定 `mtu: 1500`。
  * **解析层 (`dns`)**：在 `fake-ip-filter` 中添加 `localhost`、`127.0.0.1`，确保本地授权回调与 gRPC 环回不受代理污染；移除所有被墙海外域名，防止本地真实 DNS 污染。

---

## 🚀 跨电脑部署使用流程

1. **拷贝文件**：将 `ClashVergeSync` 整个文件夹拷贝到目标电脑。
2. **运行部署**：右键点击 **`双击一键统一部署.bat`**，选择 **“以管理员身份运行”**，等待脚本全自动运行并重启客户端。
3. **导入订阅**：在重启后的 Clash Verge 界面中，点击 **“配置 (Profiles)”**，手动贴入您个人的订阅链接进行导入，并左键选中。
4. **启用合并模式**：右键点击该订阅卡片，选择配置合并为 **“Merge”** 模式，再次右键选择 **“刷新/重新加载 (Refresh)”** 以合入全局覆写规则。
