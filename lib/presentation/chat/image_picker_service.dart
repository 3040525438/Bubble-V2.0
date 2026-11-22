// 聊天选图服务（T12.2）：把 image_picker 收敛为可注入接口（测试不触碰平台通道）。
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// 用户选中的图片（仅内存，发送后由附件仓储落盘）
class PickedImage {
  const PickedImage({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;
}

abstract class ImagePickerService {
  /// 多选图片；用户取消返回空列表
  Future<List<PickedImage>> pickImages();
}

/// 真机实现：系统相册多选（压缩质量 88%，避免原图过大）
class DeviceImagePickerService implements ImagePickerService {
  DeviceImagePickerService({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<List<PickedImage>> pickImages() async {
    final files = await _picker.pickMultiImage(imageQuality: 88);
    final result = <PickedImage>[];
    for (final file in files) {
      result.add(
        PickedImage(bytes: await file.readAsBytes(), fileName: file.name),
      );
    }
    return result;
  }
}
