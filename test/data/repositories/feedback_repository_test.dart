// 反馈仓储测试（T14.2）：记录、最新、历史、撤销幂等与统计。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/feedback_repository.dart';
import 'package:bubble/domain/feedback/feedback_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late FeedbackRepository repo;
  var now = DateTime.utc(2026, 11, 20, 10);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    now = DateTime.utc(2026, 11, 20, 10);
    repo = FeedbackRepository(db, clock: () => now);
  });

  tearDown(() async {
    await db.close();
  });

  test('记录反馈并写 journal 留痕', () async {
    final entry = await repo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_1',
      verdict: FeedbackVerdict.like,
    );
    expect(entry.id.startsWith('fb_'), isTrue);
    expect(entry.targetKind, FeedbackTargetKind.post);
    expect(entry.verdict, FeedbackVerdict.like);
    expect(entry.isReverted, isFalse);

    final logs = await db.select(db.journalLogs).get();
    expect(logs.any((l) => l.entityTable == 'feedback_records'), isTrue);
  });

  test('latestFor 返回最新未撤销反馈', () async {
    await repo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_1',
      verdict: FeedbackVerdict.like,
    );
    now = now.add(const Duration(minutes: 1));
    final second = await repo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_1',
      verdict: FeedbackVerdict.dislike,
      note: '不喜欢这个语气',
    );

    final latest = await repo.latestFor(FeedbackTargetKind.post, 'post_1');
    expect(latest?.id, second.id);
    expect(latest?.verdict, FeedbackVerdict.dislike);
  });

  test('撤销后不再出现在最新反馈中，重复撤销幂等', () async {
    final entry = await repo.record(
      kind: FeedbackTargetKind.expressionStyle,
      targetId: 'style_1',
      verdict: FeedbackVerdict.adjust,
    );
    final reverted = await repo.revert(entry.id);
    expect(reverted.isReverted, isTrue);

    final again = await repo.revert(entry.id);
    expect(again.revertedAt, reverted.revertedAt);

    final latest = await repo.latestFor(
      FeedbackTargetKind.expressionStyle,
      'style_1',
    );
    expect(latest, isNull);
  });

  test('历史按时间倒序并可按类型过滤', () async {
    await repo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_1',
      verdict: FeedbackVerdict.like,
    );
    now = now.add(const Duration(minutes: 1));
    await repo.record(
      kind: FeedbackTargetKind.memoryCorrection,
      targetId: 'mem_1',
      verdict: FeedbackVerdict.correct,
      note: '记忆有误',
    );

    final all = await repo.recent();
    expect(all, hasLength(2));
    expect(all.first.targetKind, FeedbackTargetKind.memoryCorrection);

    final posts = await repo.recent(kind: FeedbackTargetKind.post);
    expect(posts, hasLength(1));
  });

  test('统计生效与已撤销数量', () async {
    final first = await repo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_1',
      verdict: FeedbackVerdict.like,
    );
    await repo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_2',
      verdict: FeedbackVerdict.like,
    );
    await repo.revert(first.id);

    final summary = await repo.summary();
    expect(summary.total, 2);
    expect(summary.active, 1);
    expect(summary.reverted, 1);
    expect(summary.byKind[FeedbackTargetKind.post], 2);
  });

  test('非法输入抛 ArgumentError', () async {
    expect(
      () => repo.record(
        kind: FeedbackTargetKind.post,
        targetId: '',
        verdict: FeedbackVerdict.like,
      ),
      throwsArgumentError,
    );
  });
}
