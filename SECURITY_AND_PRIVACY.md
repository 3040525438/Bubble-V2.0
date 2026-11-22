# 泡泡 Bubble V2.0 — 隐私、安全与数据管理（SECURITY_AND_PRIVACY）

---

## 1. 应用锁（FR-SEC-01）

| 项 | 方案 |
| -- | -- |
| Face ID | local_auth 3.0.2（`biometricOnly: true` 可选配置，失败回退设备密码） |
| 独立应用密码 | 4~6 位数字，PBKDF2 派生校验哈希存 flutter_secure_storage（Keychain），不用明文 |
| 后台自动锁定 | App 退后台计时，超过可配置时长（立即/1min/5min/15min）回锁 |
| 连续验证失败保护 | 5 次失败递增延迟（1/5/15/30min），10 次失败要求 Face ID 或抹除数据（用户可选策略） |
| 锁定时间设置 | app_settings 持久化 |
| 边界 | 本地锁是"防随手翻看"，不是密码学强防护（越狱设备无绝对防护，诚实声明） |

## 2. API Key 安全存储（FR-SEC-02/05）

- flutter_secure_storage 10.3.1 → iOS Keychain，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（不随 iTunes 备份导出、仅本机可解）
- DB 中只存 Keychain 键名引用（models.api_key_secure_key），**不落明文**
- 内存中 Key 使用后不打印日志；错误上报脱敏
- **诚实声明（FR-SEC-05）**：客户端保存的 Key 无法防越狱提取与内存读取，本项目不做绝对安全承诺；文档与 UI 均不使用"绝对安全"表述。

## 3. 数据库加密

| 方案 | 现状与结论 |
| -- | -- |
| **主方案：SQLCipher** | sqlite3.dart 3.x 已官方接管（sqlcipher_flutter_libs 0.7.0+eol 提示改用 sqlite3 3.x）；drift 支持加密打开。**实现细节与 iOS 真机构建需在阶段 1 验证**，未验证前标注「待验证」 |
| 降级方案：应用层加密 | 若 SQLCipher 集成受阻：对敏感列（记忆正文/消息正文不加密以保检索，Key/备份密钥等敏感 KV 用 AES-GCM 加密存储），检索索引列保持明文哈希/分词词（词表可重建、不含原文全句）——**检索能力与加密的取舍在实施时如实向用户汇报** |
| 密钥管理 | DB 密钥随机生成存 Keychain；备份导出时用户可设导出密码（PBKDF2+AES-GCM 加密备份包） |

## 4. 附件安全（FR-SEC-02/03）

- 存储：应用沙盒 Documents/Attachments/<yyyy>/<mm>/；DB 存相对路径（防路径泄露含义，ADR-6）
- 路径安全：所有附件访问经 AttachmentStore 校验（拒绝 ../ 逃逸，借鉴 dsh safeJoin 思路）
- 附件缺失检查：数据中心「完整性检查」扫描 DB 记录 vs 文件（broken/orphan 双向）
- 孤立附件清理：先列清单 → 用户确认 → 删除（不自动删）
- 删除一致性：删消息询问连删附件（FR-SEC-04）；事务删记录、文件删除失败转 orphan 由清理流程兜底

## 5. 备份与恢复（FR-SEC-03、FR-DB-02）

- 备份包 = DB 文件 + 附件目录 + manifest.json（表计数对账、sha256、schema 版本、备份时间）
- 备份记录 backup_records；恢复前强制校验 sha256 + 计数对账，通过才执行
- 恢复流程：二次确认 → 当前库先自动备份（防误恢复）→ 恢复 → 索引按需重建 → 完整性复查
- 密钥依赖：本机 Keychain 中的 DB 密钥与备份包绑定时，恢复到新设备需用户输入备份密码或迁移密钥（流程在实施阶段细化，标注「待验证」）
- 删除全部数据：展示范围清单（各表行数+附件大小），备份文件独立确认是否保留（FR-SEC-04）

## 6. 数据导出（FR-MISC-04、FR-DIA-01）

- JSON 全量导出（机器可回灌）
- Markdown 按域导出：人格/记忆/说说/日记/信件/共同经历（人类可读，含 frontmatter 式元数据，借鉴 dsh 存储格式的人类可读性）
- 导出文件经系统分享面板保存到用户指定位置

## 7. 重要修改记录与审计（FR-SEC-02）

- journal_logs 全域记录（谁/何时/改了什么的有界摘要/原因/来源）
- 人格变更、记忆状态迁移、删除、备份恢复、通知安排/取消均有日志
- 数据中心提供「最近重要变更」视图

## 8. 数据库完整性与损坏恢复（FR-DB-02）

见 DATABASE_DESIGN §5：quick_check 定检、WAL、坏行隔离 quarantine、备份恢复兜底。

## 9. 隐私设计总原则

1. 数据不出本机：唯一外发数据=模型调用上下文（DeepSeek），调用前机密扫描（MEMORY_DESIGN §5）防止凭据外泄
2. 无遥测、无统计上报、无云同步
3. 通知隐私三档（FR-IOS-08）
4. 敏感类别记忆默认不自动保存（FR-MEM-05）
5. 提示注入防护：记忆/模型输出视为不可信输入，defang+结构校验（借鉴 dsh privacy.md 纵深防御思路，并如实声明"这是纵深防御而非密码学保证"）
