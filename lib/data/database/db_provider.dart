// 数据库单例持有者（T2.1 接入）：正式运行用加密库，未初始化时降级内存库
// （widget 测试/异常兜底），保证 UI 永不因数据库不可用而崩溃。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';
import 'open_db.dart';

class AppDb {
  AppDb._();

  static AppDatabase? _instance;

  /// 全局数据库实例（未初始化时使用内存库，仅开发/测试场景）
  static AppDatabase get instance =>
      _instance ??= AppDatabase(openInMemoryDatabase());

  /// 应用启动时调用：打开加密库（SQLCipher + Keychain 密钥）。
  static Future<void> initialize() async {
    if (_instance != null) return;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}bubble.db');
    final key = await obtainDatabaseKey();
    _instance = AppDatabase(openEncryptedDatabase(file, key));
    // 触发建库/迁移（drift 懒执行）
    await _instance!.customSelect('SELECT 1').get();
  }

  /// 测试注入/替换（仅测试使用）
  @visibleForTesting
  static void overrideInstance(AppDatabase db) => _instance = db;
}
