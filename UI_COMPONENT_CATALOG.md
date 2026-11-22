# 泡泡 Bubble V2.0 — 组件目录（UI_COMPONENT_CATALOG）

> 版本：v1.0（2026-11-22）｜Flutter 实现时的组件清单；所有组件已在 `design/UI_PROTOTYPE.html` 以 CSS 类呈现，类名可作命名参照。

---

## 1. 基础原子（Atom）

| 组件 | 原型类 | 变体 | 状态 |
| -- | -- | -- | -- |
| 主按钮 | `.btn.btn-p` | 全宽 / flex:1 | 默认 / 按压(加深) / 禁用(40%透明) |
| 次按钮 | `.btn.btn-s` | 同上 | 同上 |
| 危险按钮 | `.btn.btn-d` | 同上 | 同上 |
| 徽章 | `.badge` + `.b-blue/.b-lav/.b-pink/.b-green/.b-warn/.b-red` | 语义 6 色 | 可作按钮（加 cursor + data-nav） |
| 筛选 chip | `.chip` | 选中 `.on`（蓝底白字）/ 未选 | 单选组/多选组 |
| 分段控件 seg | `.seg > button` | 选中 `.on`（白底阴影浮起） | 2~4 段 |
| 单选圈 | `.radio` | 选中 `.on`（蓝实心+内环） | 表单确认 |
| 头像 | `.avatar .av-bubble/.av-user` | `.av-sm`(30px) / 默认(40px) / `.big-avatar`(84px) | 光晕常驻 |
| 语义色点 | 内联 span 10px 圆 | 蓝/紫/粉/黄 | 记忆类型标识 |
| 进度条 | 内联双层 div | 渐变填充 | 迁移/备份进度 |
| 柱状图 | `.bars > i` | 高度百分比 | 模型用量 |
| 图片占位块 | `.imggrid .ph` / 说说渐变块 | 1:1 / 110px | 设计占位 |
| 搜索条 | `.card.row` 内嵌图标+文字 | 静态展示 | — |

## 2. 容器组件（Molecule）

| 组件 | 原型类 | 解剖 |
| -- | -- | -- |
| 卡片 | `.card` | surface 圆角 20 + 柔投影 + 16 内边距；可加虚线/实线彩描边表示特殊态 |
| 分区标题 | `.t1` 裸排 | 15pt/600 + 8px 下距 |
| 月份/日期分隔 | `.month` | surfaceAlt 胶囊 11pt |
| 时间分隔条 | `.tdiv` | 居中雾蓝胶囊（聊天） |
| 字段行 | `.field` | label(12pt/次色) + 值区(surfaceAlt 圆角 14) |
| 锁条 | `.lock` | 说明文案 + 可选锁图标——「只有你能改/只追加/不可修改」统一视觉 |
| 空状态 | `.empty` | 虚线雾蓝框 + 12pt 次色说明（正式实现升级为云朵插画版） |
| 双栏 diff | `.diffgrid > .dcol(.new)` | 左原文/右修改（浅绿底）；`del` 红、`ins` 绿 |
| 时间轴 | `.tl + .tl-item(.lav/.pink)` | 左轴 + 描边色节点 + 卡片 |
| 纸张卡 | `.paper` | 顶部横线纹理 + 内容；可叠 `.stamp` 虚线圆章（已归档/已寄出） |
| 图片网格 | `.imggrid` | 3 列 1:1 圆角 12 |

## 3. 组合组件（Widget）

| 组件 | 构成 | 出现页面 |
| -- | -- | -- |
| 底部导航胶囊 | `.tabbar` + `.tab(.on) > .pill + svg + 文字` | 主壳层 4 页 |
| FAB | `.fab`（想想/＋ 两变体） | 首页、说说页 |
| 思考状态条 | `.thinkbar` + `.thinkdot`（呼吸） | 首页 |
| 会话卡 | 双头像叠放 + 标题 + 摘要 + 未读徽章 + 时间 | 首页 |
| 消息气泡 | `.msg(.me) + .bubble(.ai/.me) + .mtime + .avatar`；变体：`.typing`、失败描边气泡 | 聊天 |
| 来源标注条 | `.srcnote`（淡紫虚线） | 聊天 |
| 输入条 | `.inputbar`（+ 占位 + 发送圆钮） | 聊天 |
| 思考抽屉 | `.overlay + .drawer` + `.step(.done/.cur)` ×8 + 统计徽章 | 思考进度 |
| 审批建议卡 | 虚线淡紫卡 + diffgrid + 原因 + 三按钮行 | 人格成长层、记忆收件箱 |
| 记忆卡 | 色点 + 标题★ + 来源行 + 类型·置信徽章 | 记忆总览 |
| 证据卡 | surfaceAlt 摘录行 +「跳原消息」徽章 | 记忆详情/收件箱/冲突裁决 |
| 冲突双栏卡 | `.diffgrid` 内两张 `.card.dcol` | 冲突裁决 |
| 设置行 | `.card.row` = 标题 + 副文案 + 右侧操作徽章 | 设置主页 |
| 选项卡 | `.card` + `.radio` + 预览块 + 说明 | 通知隐私 |
| 状态行 | 状态徽章 + 说明 | 数据中心 |
| 危险区卡 | 浅红描边卡 + b-red 徽章 + 危险按钮 | 数据中心 |
| 通知预览条 | 深蓝底圆角 14 白字（🔔 …） | 通知隐私 |
| 信件卡 | 方向头像 + 标题 + 摘要 + 状态徽章 | 信件列表 |
| 日记卡 | 标题 + 来源徽章 + 日期摘要行 | 日记列表 |
| 搜索结果行 | 高亮文本（`.hl`）+ 来源行 + 计数徽章 | 全局搜索 |
| 导航栏 | `.navbar`：返回圆钮 + 标题 + 右徽章 | 全部次级页 |

## 4. 状态清单

每个列表类页面必须实现四态：

| 状态 | 视觉 |
| -- | -- |
| 加载 | 骨架屏（surfaceAlt 圆角块 + 轻脉冲） |
| 空 | 云朵插画 + 引导文案（如「还没有对话，跟泡泡说声你好吧」） |
| 错误 | 错误卡（原因文案 + 可执行动作按钮：重试/检查网络） |
| 数据 | 正常列表 |

气泡消息四态：发送中 ⏳ / 已发送 ✓ / 失败 ⚠️（可重试）/ 生成中（三点漂浮）。

## 5. 语义色使用速查

| 语义 | 用在哪 |
| -- | -- |
| 蓝 `primary` | 主操作、选中态、聊天域、记忆「约定」类、计数徽章 |
| 紫 `lavender` | 思考/记忆域：状态条、收件箱、成长建议、AI 整理标记、关联记忆 |
| 粉 `pink` | 说说/情感域：心情徽章、信件、偏好类记忆 |
| 绿 `success` | 已确认/已寄出/正常/置信高 |
| 黄 `warn` | 冲突/草稿/待裁决/需人工选择 |
| 红 `danger` | 删除/失败/不可逆操作 |

## 6. 命名建议（Flutter 映射）

- 原型 CSS 类名 → Flutter 组件名：`card`→`BubbleCard`，`badge`→`SemanticBadge`，`chip`→`FilterChip`（复用 Material 后定制），`thinkbar`→`ThinkingStatusBar`，`srcnote`→`ProactiveSourceNote`，`paper`→`PaperCard`，`drawer`→`ThinkDrawer`，`seg`→`BubbleSegmented`。
- Token 映射：`design/UI_PROTOTYPE.html` 的 CSS 变量一一对应 Flutter `ThemeExtension<BubbleColors>`，禁止硬编码色值。
