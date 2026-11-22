// 模型管理页（T3.3）：模型注册/启停/默认/参数/能力徽章/连接测试 + 用量统计。
// 依据 UI_PAGE_SPEC §24、DATABASE_DESIGN §2.22~§2.23、REQUIREMENTS FR-MDL-01~03。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../data/api/deepseek_client.dart';
import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/model_repository.dart';
import '../../domain/chat/chat_error.dart';
import '../../domain/chat/chat_provider.dart';
import '../theme/bubble_colors.dart';

class ModelManagePage extends StatefulWidget {
  const ModelManagePage({super.key, this.repository});

  final ModelRepository? repository;

  @override
  State<ModelManagePage> createState() => _ModelManagePageState();
}

class _ModelManagePageState extends State<ModelManagePage> {
  late final ModelRepository _repo =
      widget.repository ?? ModelRepository(AppDb.instance);

  Stream<List<ModelRecord>>? _stream;
  final Map<String, String?> _keyFields = {};
  List<DailyUsage> _week = const [];
  DailyUsage? _month;
  Map<String, int> _scenes = const {};
  String? _testingId;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _repo.ensureSeed();
    if (!mounted) return;
    setState(() => _stream = _repo.watchModels());
    await _reloadKeys();
    await _refreshUsage();
  }

  Future<void> _reloadKeys() async {
    final models = await _repo.listModels();
    for (final model in models) {
      _keyFields[model.id] = await _repo.readApiKey(model);
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshUsage() async {
    final week = await _repo.usageLastDays(7);
    final month = await _repo.usageThisMonth();
    final scenes = await _repo.usageBySceneThisMonth();
    if (!mounted) return;
    setState(() {
      _week = week;
      _month = month;
      _scenes = scenes;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 2600),
      ));
  }

  Future<void> _openEditor({ModelRecord? model}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ModelEditDialog(repository: _repo, model: model),
    );
    if (saved != true || !mounted) return;
    await _reloadKeys();
    await _refreshUsage();
    _toast(model == null ? '模型已添加' : '模型已更新');
  }

  Future<void> _toggleEnabled(ModelRecord model, bool enabled) async {
    await _repo.setEnabled(model.id, enabled);
    if (!mounted) return;
    if (!enabled) _toast('已停用「${model.displayName}」');
  }

  Future<void> _setDefault(ModelRecord model) async {
    await _repo.setDefault(model.id);
    if (!mounted) return;
    _toast('已将「${model.displayName}」设为默认');
  }

  Future<void> _delete(ModelRecord model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('删除「${model.displayName}」会一并清除它的 API Key 记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
                foregroundColor: context.bubbleColors.dangerDeep),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.deleteModel(model.id);
    if (!mounted) return;
    _keyFields.remove(model.id);
    _toast('模型已删除');
  }

  /// 连接测试：真实请求一次（会消耗少量 token），失败按错误矩阵给出文案。
  Future<void> _testConnection(ModelRecord model) async {
    final apiKey = _keyFields[model.id];
    if (apiKey == null || apiKey.isEmpty) {
      _toast('请先编辑模型并填写 API Key');
      return;
    }
    setState(() => _testingId = model.id);
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final client = DeepSeekClient(
        dio: dio,
        apiKey: apiKey,
        baseUrl: model.apiBaseUrl ?? kDeepSeekDefaultBaseUrl,
      );
      final delta = await client
          .streamChat(
            modelTag: model.modelTag,
            history: const [ChatTurn(role: 'user', content: '你好')],
            params: const {'max_tokens': 8},
          )
          .firstWhere((d) => d.text.isNotEmpty)
          .timeout(const Duration(seconds: 30));
      _toast('连接成功：收到「${_clip(delta.text)}」');
    } on ChatFailure catch (error) {
      _toast(error.userMessage);
    } catch (error) {
      _toast('连接失败：请检查网络与参数');
    } finally {
      if (mounted) setState(() => _testingId = null);
    }
  }

  String _clip(String text) {
    final trimmed = text.trim();
    return trimmed.length <= 12 ? trimmed : '${trimmed.substring(0, 12)}…';
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      appBar: AppBar(
        title: const Text('模型管理'),
        actions: [
          IconButton(
            tooltip: '添加模型',
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add_circle_outline_rounded),
          ),
        ],
      ),
      body: StreamBuilder<List<ModelRecord>>(
        stream: _stream,
        builder: (context, snapshot) {
          final models = snapshot.data ?? const <ModelRecord>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Text(
                '聊天使用的模型',
                style: TextStyle(
                  fontSize: BubbleFontSize.cardTitle,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
                ),
              ),
              const SizedBox(height: 8),
              if (!snapshot.hasData)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (models.isEmpty)
                Text('还没有模型，点右上角添加',
                    style: TextStyle(
                        fontSize: BubbleFontSize.secondary,
                        color: onSurface.withValues(alpha: 0.5)))
              else
                for (final model in models) _buildModelCard(model, semantic),
              const SizedBox(height: 18),
              Text(
                '用量（本月）',
                style: TextStyle(
                  fontSize: BubbleFontSize.cardTitle,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
                ),
              ),
              const SizedBox(height: 8),
              _buildUsageCard(semantic),
              const SizedBox(height: 18),
              Text(
                '本地模型',
                style: TextStyle(
                  fontSize: BubbleFontSize.cardTitle,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: semantic.surfaceAlt,
                  borderRadius: BorderRadius.circular(BubbleRadius.card),
                ),
                child: Row(
                  children: [
                    Icon(Icons.memory_rounded,
                        size: 20, color: onSurface.withValues(alpha: 0.35)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '本地模型预留（后续版本支持，当前不可用）',
                        style: TextStyle(
                          fontSize: BubbleFontSize.secondary,
                          color: onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '费用为按官方价目估算（输入 ¥2/百万 · 输出 ¥8/百万，reasoner 更高），'
                '仅作参考，以 DeepSeek 账单为准。API Key 存储在本机系统钥匙串，不写入数据库。',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  height: 1.6,
                  color: onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModelCard(ModelRecord model, BubbleSemanticColors semantic) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final surface = Theme.of(context).colorScheme.surface;
    final capabilities = ModelCapabilities.parse(model.capabilities);
    final params = ModelParams.parse(model.params);
    final hasKey = (_keyFields[model.id] ?? '').isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(
          color: model.isDefault == 1 ? semantic.bubbleUserA : semantic.stroke,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      model.displayName,
                      style: TextStyle(
                        fontSize: BubbleFontSize.body,
                        fontWeight: FontWeight.w600,
                        color: onSurface,
                      ),
                    ),
                    if (model.isDefault == 1) ...[
                      const SizedBox(width: 6),
                      _Badge(text: '默认', color: semantic.bubbleUserA),
                    ],
                    const SizedBox(width: 6),
                    _Badge(
                      text: hasKey ? '已配置 Key' : '未配置 Key',
                      color: hasKey ? semantic.success : semantic.mist,
                      filled: hasKey,
                    ),
                  ],
                ),
              ),
              Switch(
                value: model.enabled == 1,
                onChanged: (value) => _toggleEnabled(model, value),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${model.modelTag} · ${model.apiBaseUrl ?? kDeepSeekDefaultBaseUrl}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (capabilities.streaming)
                _Badge(text: '流式', color: semantic.lavenderDeep),
              _Badge(
                  text: '上下文 ${capabilities.contextLabel}',
                  color: semantic.lavenderDeep),
              if (capabilities.reasoning)
                _Badge(text: '推理链', color: semantic.lavenderDeep),
              _Badge(
                  text: '温度 ${params.temperature.toStringAsFixed(2)}',
                  color: semantic.lavenderDeep),
              _Badge(
                  text: '最大 ${params.maxTokens} tokens',
                  color: semantic.lavenderDeep),
              if (!capabilities.vision)
                _Badge(text: '无视觉', color: semantic.mist),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton(
                onPressed: () => _openEditor(model: model),
                child: const Text('编辑'),
              ),
              TextButton(
                onPressed: _testingId == model.id
                    ? null
                    : () => _testConnection(model),
                child: Text(_testingId == model.id ? '连接中…' : '测试连接'),
              ),
              if (model.isDefault != 1)
                TextButton(
                  onPressed: () => _setDefault(model),
                  child: const Text('设为默认'),
                ),
              const Spacer(),
              IconButton(
                tooltip: '删除模型',
                onPressed: () => _delete(model),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 19, color: semantic.dangerDeep),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUsageCard(BubbleSemanticColors semantic) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final surface = Theme.of(context).colorScheme.surface;
    final month = _month;
    final maxCost = _week.fold<double>(0, (max, p) => p.cost > max ? p.cost : max);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '¥${(month?.cost ?? 0).toStringAsFixed(3)}',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${month?.totalTokens ?? 0} tokens · ${month?.requests ?? 0} 次',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final point in _week)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          point.requests == 0
                              ? ''
                              : '¥${point.cost.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 9,
                            color: onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Container(
                          width: 14,
                          height: maxCost <= 0
                              ? 4
                              : 6 + 54 * (point.cost / maxCost),
                          decoration: BoxDecoration(
                            color: point.cost > 0
                                ? semantic.bubbleUserA
                                : semantic.mist,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          point.day.substring(5),
                          style: TextStyle(
                            fontSize: 9,
                            color: onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (_scenes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(color: semantic.stroke, height: 1),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _scenes.entries)
                  Text(
                    '${_sceneLabel(entry.key)} ${entry.value} tokens',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _sceneLabel(String scene) {
    switch (scene) {
      case 'chat':
        return '聊天';
      case 'memory_extract':
        return '记忆提取';
      case 'thinking':
        return '自主思考';
      case 'proactive':
        return '主动行为';
      default:
        return scene;
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.color,
    this.filled = false,
  });

  final String text;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: filled ? Colors.white : color,
        ),
      ),
    );
  }
}

/// 模型编辑/新增对话框
class _ModelEditDialog extends StatefulWidget {
  const _ModelEditDialog({required this.repository, this.model});

  final ModelRepository repository;
  final ModelRecord? model;

  @override
  State<_ModelEditDialog> createState() => _ModelEditDialogState();
}

class _ModelEditDialogState extends State<_ModelEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.model?.displayName ?? 'DeepSeek');
  late final TextEditingController _tag = TextEditingController(
      text: widget.model?.modelTag ?? kDeepSeekDefaultModelTag);
  late final TextEditingController _baseUrl = TextEditingController(
      text: widget.model?.apiBaseUrl ?? kDeepSeekDefaultBaseUrl);
  final TextEditingController _keyField = TextEditingController();

  late double _temperature =
      ModelParams.parse(widget.model?.params).temperature;
  late int _maxTokens = ModelParams.parse(widget.model?.params).maxTokens;
  late bool _enabled = widget.model?.enabled != 0;
  late bool _isDefault = widget.model?.isDefault == 1;
  late ModelCapabilities _capabilities =
      ModelCapabilities.parse(widget.model?.capabilities);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _tag.dispose();
    _baseUrl.dispose();
    _keyField.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final tag = _tag.text.trim();
    if (name.isEmpty || tag.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('显示名与模型名不能为空')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final modelId = await widget.repository.saveModel(
        id: widget.model?.id,
        displayName: name,
        modelTag: tag,
        baseUrl: _baseUrl.text.trim().isEmpty
            ? kDeepSeekDefaultBaseUrl
            : _baseUrl.text.trim(),
        params: ModelParams(
            temperature: _temperature, maxTokens: _maxTokens),
        capabilities: _capabilities,
        enabled: _enabled,
        isDefault: _isDefault,
      );
      final key = _keyField.text.trim();
      if (key.isNotEmpty) {
        await widget.repository.saveApiKey(modelId, key);
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.model != null;
    return AlertDialog(
      title: Text(isEditing ? '编辑模型' : '添加模型'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '显示名',
                  hintText: '如 DeepSeek',
                ),
              ),
              TextField(
                controller: _tag,
                decoration: const InputDecoration(
                  labelText: '模型名（model tag）',
                  hintText: 'deepseek-chat / deepseek-reasoner',
                ),
              ),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: 'API 地址',
                  hintText: kDeepSeekDefaultBaseUrl,
                ),
              ),
              TextField(
                controller: _keyField,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: isEditing ? '留空表示不修改' : 'sk-...',
                ),
              ),
              const SizedBox(height: 12),
              Text('温度 ${_temperature.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: BubbleFontSize.secondary,
                      color: Theme.of(context).colorScheme.onSurface)),
              Slider(
                value: _temperature,
                min: 0,
                max: 1.5,
                divisions: 30,
                onChanged: (value) => setState(() => _temperature = value),
              ),
              Row(
                children: [
                  Text('最大 tokens $_maxTokens',
                      style: TextStyle(
                          fontSize: BubbleFontSize.secondary,
                          color: Theme.of(context).colorScheme.onSurface)),
                  const Spacer(),
                  DropdownButton<int>(
                    value: _maxTokens,
                    items: const [512, 1024, 2048, 4096, 8192]
                        .map((v) => DropdownMenuItem(
                            value: v, child: Text('$v')))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _maxTokens = value);
                    },
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用该模型'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('设为默认模型'),
                value: _isDefault,
                onChanged: (value) => setState(() => _isDefault = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('具备视觉能力'),
                subtitle: Text(
                  '阶段 12 图片分析使用；请在确认模型支持后再开启',
                  style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.45)),
                ),
                value: _capabilities.vision,
                onChanged: (value) => setState(() => _capabilities =
                    ModelCapabilities(
                        streaming: _capabilities.streaming,
                        reasoning: _capabilities.reasoning,
                        vision: value,
                        contextLength: _capabilities.contextLength)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
