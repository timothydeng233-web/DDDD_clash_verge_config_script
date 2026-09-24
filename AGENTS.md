# Agent 项目协作与测试部署规范 (Agent Project Rules)

本文件是本项目所有 AI Agent（包括 Antigravity、Codex、Claude、Cursor 等）在进行代码编写、配置调试、测试与部署时必须严格遵守的强制性规则。

---

## 核心安全铁律 (Absolute Principles)

> [!CAUTION]
> **严禁直接在真实环境中修改与验证！**
> 任何未经隔离测试验证、且未经用户显式书面授权（明确回复“允许部署”或“确认部署”）的操作，绝对不允许直接修改、覆盖或重启任何真实生产/本机运行环境（包括但不限于 `$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\`、Windows 注册表、系统代理、物理网卡与 TUN 适配器）。

---

## 1. 强制临时隔离测试流程 (Mandatory Isolated Sandbox Testing)

所有涉及规则增删、模板调整、配置生成、PowerShell 脚本重构或网络路由调整的任务，必须严格遵循以下隔离流程：

1. **测试沙箱化**：
   - 必须使用系统临时目录（如 `[IO.Path]::GetTempPath()` 下的独立随机目录）或已明确被 `.gitignore` 排除的本地沙箱目录（如 `LocalConfig/`）进行文件生成与操作。
   - 严禁在真实用户配置目录中创建临时调试文件。

2. **配置指纹防护与零污染校验**：
   - 在开始任何测试前，Agent 必须读取并记录真实运行环境配置（包括 `verge.yaml`、`profiles.yaml`、`clash-verge.yaml` 及关键订阅文件）的 SHA256 哈希值。
   - 测试结束后，必须重新比对上述哈希值，确保真实环境配置未发生任何篡改与漂移（保持零修改、零污染）。
   - 临时生成的测试目录必须在测试结束时（无论成功与否）于 `finally` 块中彻底清理删除。

3. **内核级与规则级三重校验**：
   - **占位符与语法检查**：确保所有占位符（如 `__PROXY_GROUP__` 等）均被合法替换，不存在未定义的悬空变量。
   - **策略组真实性核验**：检查生成规则中的每一个目标策略组，必须在目标订阅的真实 `proxy-groups` 列表中存在，严禁猜测或硬编码不存在的策略组名。
   - **Mihomo 内核校验**：必须调用 `verge-mihomo.exe -t -f <临时配置文件>` 执行内核配置校验，确保内核解析通过（ExitCode == 0）。

4. **连通性与非破坏性探测**：
   - 测试应仅限只读端点探测（如 HTTP HEAD / TLS 握手测试），不得发送带认证 Token、API Key 或写入性质的危险网络请求。

---

## 2. 真实环境部署门禁与授权协议 (Deployment Gate & Authorization)

1. **审查先行**：
   - Agent 完成隔离测试后，必须向用户详细汇报测试结果（包括生成的规则差异、验证通过状态、影响范围）。
2. **用户授权前禁止行动**：
   - 在用户明确确认之前，Agent **仅允许**停留在只读审计（`Audit`）、生成沙箱文件（`Generate`）或隔离测试（`IsolatedTest`）阶段。
3. **安全部署保障**：
   - 正式部署必须通过具备自动快照和原子替换能力的流程（如 `Deploy-ClashVerge.ps1 -Action Deploy`）。
   - 部署前必须对原文件创建带时间戳的备份快照及 `manifest.json` 索引清单。
   - 部署过程若出现任何异常，必须无条件立即自动回滚快照并拉起客户端，严禁留下半破坏状态。

---

## 3. 多订阅隔离与兼容性规则 (Multi-Subscription Compatibility)

1. **禁止单一订阅偏好污染全局**：
   - 不得将特定订阅（如 `ikuuu`）特有的策略组名称（如 `🔰 选择节点`）或特定节点配置写入全局生效的合并文件（如 `profiles/Merge.yaml`）。
   - 凡是特定订阅专属的配置，必须通过**订阅级扩展（Per-profile Merge/Script）**或**带订阅名称守卫的脚本（`Script.js` 中的 `if (profileName !== 'ikuuu') return config;`）**实现逻辑隔离。
2. **保持其他订阅零影响**：
   - 必须确保当客户端切换到其他订阅（如本机的 `SakuraCat`）时，不会因缺失策略组或节点引用引发 Mihomo 内核崩溃或分流失效。
