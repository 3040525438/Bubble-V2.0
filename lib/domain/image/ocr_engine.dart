// OCR 引擎接口（T12.4，D-5 方案：iOS 本地 Vision 优先，云端视觉模型降级）。
// 现状：D-5 尚未最终确认，默认实现为「未接入」——必须明确标注，禁止假装已支持。
// 后续接入时只需新增 OcrEngine 实现并将其注入 AttachmentRepository，不影响调用方。
import 'dart:io';

/// OCR 识别结果
class OcrResult {
  const OcrResult({
    required this.text,
    required this.engineId,
    this.confidence,
  });

  final String text;
  final String engineId;
  final double? confidence;

  bool get isEmpty => text.trim().isEmpty;
}

/// OCR 引擎抽象（本地 Vision / 云端视觉模型均可实现）
abstract class OcrEngine {
  /// 引擎标识（落库与 UI 标注用）
  String get engineId;

  /// 是否可用（false 时 UI 必须明确提示「未接入」）
  bool get isAvailable;

  /// 识别单张图片；不可用或识别失败返回 null
  Future<OcrResult?> recognizeFile(File file);
}

/// 未接入 OCR（当前默认；D-5 确认前不得冒充可用）
class UnavailableOcrEngine implements OcrEngine {
  const UnavailableOcrEngine();

  @override
  String get engineId => 'unavailable';

  @override
  bool get isAvailable => false;

  @override
  Future<OcrResult?> recognizeFile(File file) async => null;
}
