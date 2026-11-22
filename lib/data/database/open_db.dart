// 数据库打开封装（T1.2/T1.3）：SQLCipher 加密 + PRAGMA 约定 + 单连接策略。
// 依据 DATABASE_DESIGN §3.1 与 sqlite3 3.x hooks 机制（TECH_STACK §3.1）。
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keychain 中保存数据库密钥的键名（不入仓库、不入日志）。
const kDbKeySecureKey = 'bubble.db.key.v1';

/// 读取（或首次生成）数据库加密密钥。
/// 密钥存 flutter_secure_storage：iOS 落 Keychain（thisDeviceOnly），
/// 阶段 0 已核对该包 iOS 行为（TECH_STACK §2）。
Future<String> obtainDatabaseKey() async {
  const storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly：重启后首次解锁可用，
      // 不随 iTunes 备份迁移到新设备（TECH_STACK §2 核对项）
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final existing = await storage.read(key: kDbKeySecureKey);
  if (existing != null && existing.isNotEmpty) return existing;
  // 首次生成 256-bit 随机密钥（密码学安全随机源）
  final bytes =
      List<int>.generate(32, (_) => Random.secure().nextInt(256));
  final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  await storage.write(key: kDbKeySecureKey, value: key);
  return key;
}

/// 打开加密数据库（应用唯一 QueryExecutor 来源，单连接策略：全 App 共享）。
///
/// - WAL 模式在连接 setup 中设置（崩溃安全 + 读写并行）
/// - PRAGMA key 必须是第一条语句（SQLCipher 要求）
/// - page_size 在空库建表前生效
QueryExecutor openEncryptedDatabase(File dbFile, String passphrase) {
  return LazyDatabase(() async {
    return NativeDatabase.createInBackground(
      dbFile,
      setup: (db) {
        // 顺序敏感：key 必须最先执行
        db.execute("PRAGMA key = '$passphrase'");
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA page_size = 4096');
      },
    );
  });
}

/// 测试用：内存库（不加密，单元测试用；加密逻辑走真机验证 T1.2）。
QueryExecutor openInMemoryDatabase() => NativeDatabase.memory();
