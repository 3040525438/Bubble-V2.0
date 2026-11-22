// 应用锁屏（T1.6 骨架）：呼吸动效头像 + Face ID/密码验证 + 失败保护。
// 依据 FR-SEC-01 / UI_DESIGN_SYSTEM §7（呼吸 breathe 2.4s）。
// local_auth 真机验证项（Face ID 权限文案与降级）待真机执行（TEST_PLAN §5）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/bubble_colors.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen>
    with SingleTickerProviderStateMixin {
  final _localAuth = LocalAuthentication();
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400), // §7 breathe 2.4s
    lowerBound: 0.9,
    upperBound: 1.0,
  )..repeat(reverse: true);

  int _failCount = 0;
  DateTime? _lockUntil; // 连续失败保护：5 次失败延迟锁定
  bool _authenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreFailState();
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  Future<void> _restoreFailState() async {
    // 失败计数跨启动持久（连续验证失败保护 FR-SEC-01）
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _failCount = prefs.getInt('lock.fail_count') ?? 0;
      final ms = prefs.getInt('lock.lock_until') ?? 0;
      _lockUntil =
          ms > DateTime.now().millisecondsSinceEpoch ? _fromMs(ms) : null;
    });
  }

  DateTime _fromMs(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms);

  Future<void> _authenticate() async {
    if (_authenticating) return;
    if (_lockUntil != null &&
        DateTime.now().isBefore(_lockUntil!)) {
      return; // 冷却中
    }
    setState(() {
      _authenticating = true;
      _error = null;
    });
    try {
      final ok = await _localAuth.authenticate(
        localizedReason: '验证以解锁泡泡',
        biometricOnly: true, // FR-SEC-01：锁定 Face ID
        persistAcrossBackgrounding: true, // 后台切换时自动恢复验证
      );
      if (!mounted) return;
      if (ok) {
        await _resetFailCount();
        if (mounted) context.go('/');
      } else {
        await _registerFailure();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '无法使用生物识别：${e.toString()}');
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  Future<void> _registerFailure() async {
    _failCount++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lock.fail_count', _failCount);
    if (_failCount >= 5) {
      // 连续 5 次失败：延迟 60s 才允许重试（失败保护）
      final until = DateTime.now().add(const Duration(seconds: 60));
      await prefs.setInt(
          'lock.lock_until', until.millisecondsSinceEpoch);
      setState(() => _lockUntil = until);
    }
    setState(() => _error = '验证失败（$_failCount/5）');
  }

  Future<void> _resetFailCount() async {
    _failCount = 0;
    _lockUntil = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lock.fail_count', 0);
    await prefs.setInt('lock.lock_until', 0);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockUntil != null && DateTime.now().isBefore(_lockUntil!);
    final semantic = context.bubbleColors;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 呼吸动效头像（§7：锁屏头像 breathe）
            ScaleTransition(
              scale: _breathe,
              child: CircleAvatar(
                radius: 44,
                backgroundColor: semantic.lavender,
                child: const Icon(Icons.water_drop_rounded,
                    size: 44, color: Colors.white),
              ),
            ),
            const SizedBox(height: 24),
            Text('泡泡已锁定', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              locked
                  ? '验证失败次数过多，请稍后再试'
                  : '验证以继续',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: semantic.dangerDeep)),
              ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: (_authenticating || locked) ? null : _authenticate,
              icon: const Icon(Icons.face_retouching_natural_rounded),
              label: Text(_authenticating ? '验证中…' : 'Face ID 解锁'),
            ),
          ],
        ),
      ),
    );
  }
}
