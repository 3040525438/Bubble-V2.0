// 安全存储抽象（T3.2）：API Key 只进 iOS Keychain / Android Keystore，
// 数据库仅存键名（DATABASE_DESIGN §2.22）。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeychainKeyStore implements SecureKeyStore {
  KeychainKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
