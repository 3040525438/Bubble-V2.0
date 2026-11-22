# 泡泡 Bubble V2.0 — 正式开发启动前检查报告（PREFLIGHT_REPORT）

> 检查日期：2026-11-22。依据：本轮对 23 份项目文档、38 页 UI 原型、工作区实际文件、开发环境命令实测输出、GitHub API 实查。无凭历史总结推断的结论。
> 配套文档：`ENVIRONMENT_AUDIT.md`（环境明细）｜`USER_PREPARATION_CHECKLIST.md`（用户准备清单）｜`BLOCKERS_AND_DEPENDENCIES.md`（阻塞与依赖）。

---

## 1. 十项检查范围逐项结论

| # | 检查项 | 结论 | 证据要点 |
| -- | -- | -- | -- |
| 1 | 规划文档 | ✅ 完整可用 | 16 份规划 md 齐全；REVIEW_REPORT 14 项审查问题全修复；D-2/3/4/6 已定案且交叉复核无矛盾 |
| 2 | UI/UX 设计 | ✅ 完整可用 | UI_PROTOTYPE.html 38 页（108KB）+ 7 份 UI 文档（提案/系统/信息架构/页面规范/交互规范/组件目录/评审）；插画资源为概念稿（可 AI 生成） |
| 3 | 现有 Flutter 代码 | ⬜ 尚未创建（预期内） | `BubbleV2/` 仅文档+原型，无 pubspec/.git——阶段 0 未执行的正常状态，不是缺陷 |
| 4 | 开发环境 | ⚠️ 主体可用，2 项待处理 | Flutter 3.24.5 可用但需升 3.50；Git/JDK17/Android SDK/模拟器 AVD 齐全；flutter doctor Android 检查崩溃（不阻塞 iOS 主线） |
| 5 | GitHub/CI 条件 | ⚠️ 账号与 CI 路线已验证，仓库待建 | 旧项目 DaFeiYu 有 GitHub 远程仓且 Actions 曾成功出未签名 IPA（工作区留有 CI 日志）；BubbleV2 仓库未建；本次 git 协议实测连接被重置（待重试） |
| 6 | iOS 构建签名条件 | ✅ 路线已验证可行 | 旧项目"CI 未签名 IPA → Windows 爱思助手签名 → 装机"已走通（IPA/正式版 存 3 个未签名 IPA）；无需 Mac、无需 CI 签名 Secrets；免费 Apple ID 7 天有效期风险已在 R-04 登记 |
| 7 | DeepSeek 接入条件 | ⬜ 无 Key（不阻塞开发） | 按设计阶段 3 前用 EchoProvider 假模型；Key 届时 App 内录入 Keychain，不入聊天/源码；需充值（费用低，额度你定） |
| 8 | AstrBot 迁移条件 | ⚠️ 备份雏形在，缺 11-03 后数据确认 | 两份拷贝（`_migration_copy_20261116` 837 文件 + `_astrbot_review`）内容一致：data_v4.db(WAL=0) / chat_memory.db 17MB / memory.db 2.6MB / companions.json 5MB / 日记 10-24~11-02 / 信件 / books / knowledge_base 全在；无 sha256 清单；**日记信件止于 11-02，需确认旧服务器之后是否还有数据** |
| 9 | iPhone 17 Pro 真机条件 | ✅ 无需提前准备特殊材料 | 爱思助手路线已验证；Windows+模拟器可完成全部非真机项；真机仅在 4 个节点必须出现 |
| 10 | 正式功能开发依赖 | ✅ 全部具备实施条件 | 数据库 29+3 表字段级设计、五层架构、15 阶段路线图、测试计划六大域齐备；无架构级未决冲突 |

## 2. 分级结论（摘要，详见 USER_PREPARATION_CHECKLIST）

- **A. 开发前必须（3 项）**：GitHub 仓库与公开/私有决定（A-1）、Bundle ID 前缀（A-2）、D-1/D-8 决策点头（A-3）。全部是"确认"性质，零费用、零下载。
- **B. 开发过程中再准备**：DeepSeek API Key+充值（阶段 3 前）、D-5 OCR 确认（阶段 12 前）、AstrBot 11-03 后数据补齐（阶段 14 前）、UQ-1~7 设计确认（阶段 1 前）、权限文案（阶段 13 前）。
- **C. 真机验收前准备**：爱思助手可用确认、Apple ID 自签（免费路线，7 天重签）、阶段 13/15 真机配合观察。
- **D. 不需要准备（TRAE 自完成）**：Flutter 升级、工程创建、git init、CI workflow、sha256 清单、全部代码与测试；**不需要任何服务器、不需要新注册任何第三方账号**（除 DeepSeek 外）。

## 3. 安全与隐私核查

| 风险点 | 现状 | 措施 |
| -- | -- | -- |
| 仓库公开导致源码泄露 | 旧仓库 DaFeiYu 实测为**公开**（匿名 API 200） | V2 建议私有仓库；含个人记忆/人格数据结构设计 |
| API Key 入仓库 | 当前无任何 Key 在工作区明文存在（已确认不需要迁移旧 Key） | Keychain 路线 + .gitignore + 测试录制回放不含真实 Key |
| AstrBot 原始数据 | 两份拷贝只读保留在工作区，未改动 | 阶段 0 生成 sha256 清单双副本；仓库 .gitignore 排除数据目录 |
| 签名材料 | 无需进仓库（爱思助手本机签名路线） | CI 只出未签名 IPA，Secrets 无签名材料需求 |

## 4. 本轮执行边界遵守情况

- ✅ 仅阅读/检查/创建 4 份检查文档；未进行任何业务功能开发。
- ✅ 未删除或覆盖任何原始数据（含旧项目遗留物全部原样保留）。
- ✅ 未创建付费服务、未提交任何真实 Key、未擅自确定 Bundle ID。
- ✅ 环境仅做只读检测，无修改性操作，无需记录修复项。
- ⚠️ MCP Feedback Enhanced 本会话不可用（无此工具可调用），按惯例以文字停点代替。

## 5. 最终停点声明

本轮 Preflight 完成。四份报告位于 `BubbleV2/`：本文件、`ENVIRONMENT_AUDIT.md`、`USER_PREPARATION_CHECKLIST.md`、`BLOCKERS_AND_DEPENDENCIES.md`。

**等待你完成 A 级三项准备（或确认按替代方案先行）并正式发出全项目自主开发授权后，才进入阶段 0 实施。**
