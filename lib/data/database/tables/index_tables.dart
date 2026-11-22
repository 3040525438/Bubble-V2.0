// 派生索引表（§2.30）：可重建，绝非事实来源（FR-MEM-06）。
// 索引失效判定（版本不匹配/校验失败/手动触发）→ 全量重建，零数据丢失。
// 相似度：重叠系数 |A∩B|/min(|A|,|B|)，用 ≥2 字 token + 拉丁词。
import 'package:drift/drift.dart';

// 记忆检索倒排：CJK 单字+双字、拉丁词；字段权重 标题8/别名标签6/摘要3/正文1
@DataClassName('MemoryIndexTerm')
class MemoryIndexTerms extends Table {
  TextColumn get token => text()();
  TextColumn get docId => text()();
  IntColumn get fieldWeight => integer()();

  @override
  Set<Column> get primaryKey => {token, docId};
}

// 记忆文档元数据缓存（checksum 用于失效判定）
@DataClassName('MemoryIndexDoc')
class MemoryIndexDocs extends Table {
  TextColumn get docId => text()();
  TextColumn get type => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get title => text().nullable()();
  TextColumn get preview => text().nullable()();
  IntColumn get importance => integer().nullable()();
  IntColumn get pinned => integer().nullable()();
  IntColumn get updatedAt => integer().nullable()();
  TextColumn get checksum => text().nullable()();

  @override
  Set<Column> get primaryKey => {docId};
}

// 全局搜索倒排（聊天/说说/日记/信件/经历/附件OCR，FR-MISC-03）
@DataClassName('ContentIndexTerm')
class ContentIndexTerms extends Table {
  TextColumn get token => text()();
  TextColumn get docKind => text()(); // chat/post/diary/letter/experience/attachment
  TextColumn get docId => text()();
  IntColumn get fieldWeight => integer()();

  @override
  Set<Column> get primaryKey => {token, docKind, docId};
}
