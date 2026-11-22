// 测试用内存 Key 存储（替代系统钥匙串，避免平台通道）
import 'package:bubble/data/security/secure_key_store.dart';

class InMemoryKeyStore implements SecureKeyStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
