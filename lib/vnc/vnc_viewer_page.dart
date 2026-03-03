import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'vnc_client_manager.dart';

/// VNC 远程桌面查看器页面。
class VncViewerPage extends StatefulWidget {
  final VncClientManager manager;
  const VncViewerPage({super.key, required this.manager});

  @override
  State<VncViewerPage> createState() => _VncViewerPageState();
}

class _VncViewerPageState extends State<VncViewerPage> {
  final TransformationController _transformController =
      TransformationController();

  /// 用 ValueNotifier 单独驱动图像更新，避免帧更新触发整个 build()。
  late final ValueNotifier<ui.Image?> _imageNotifier;

  VncClientManager get _manager => widget.manager;

  bool _isShowingDisconnectDialog = false;
  bool _isExiting = false;
  bool _enableMouseEvents = false;

  // ── 触摸暂停 ──────────────────────────────────────────────────────────────

  int _activePointers = 0;
  Timer? _resumeTimer;

  /// 手指离开后恢复渲染的延迟。
  /// 对齐到 vsync 节奏：Android 等 2 帧（~33ms@60fps），iOS 等 1 帧。
  static final Duration _resumeDelay = Duration(
    milliseconds: Platform.isAndroid ? 33 : 16,
  );

  @override
  void initState() {
    super.initState();
    _imageNotifier = ValueNotifier(_manager.currentImage);
    _manager.addListener(_onManagerUpdate);
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _manager.removeListener(_onManagerUpdate);
    _manager.disconnect(silent: true);
    _manager.dispose();
    _transformController.dispose();
    _imageNotifier.dispose();
    super.dispose();
  }

  void _onManagerUpdate() {
    if (!mounted || _isExiting) return;

    if (_manager.state == VncConnectionState.error ||
        _manager.state == VncConnectionState.disconnected) {
      _showDisconnectedDialog();
      return;
    }

    if (_activePointers > 0 || _resumeTimer != null) return;

    _imageNotifier.value = _manager.currentImage;
  }

  void _showDisconnectedDialog() {
    if (!mounted || _isShowingDisconnectDialog || _isExiting) return;
    _isShowingDisconnectDialog = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('连接已断开'),
        content: Text(_manager.errorMessage ?? '与服务器的连接已丢失。'),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _exitPage();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ).then((_) => _isShowingDisconnectDialog = false);
  }

  Future<bool> _onWillPop() async {
    if (_isExiting) return false;
    if (await _showDisconnectConfirmation()) _exitPage();
    return false;
  }

  Future<bool> _showDisconnectConfirmation() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开连接？'),
        content: const Text('确定要断开与远程桌面的连接吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _exitPage() {
    if (_isExiting || !mounted) return;
    _isExiting = true;
    Navigator.of(context).pop();
  }

  Offset? _toFrameBufferCoords(Offset localPosition, Size widgetSize) {
    final int fbW = _manager.frameBufferWidth;
    final int fbH = _manager.frameBufferHeight;
    if (fbW == 0 || fbH == 0) return null;

    final Matrix4 inv = Matrix4.inverted(_transformController.value);
    final Offset scene = MatrixUtils.transformPoint(inv, localPosition);

    final double wAsp = widgetSize.width / widgetSize.height;
    final double fAsp = fbW / fbH;
    double dw, dh, ox = 0, oy = 0;

    if (fAsp > wAsp) {
      dw = widgetSize.width;
      dh = widgetSize.width / fAsp;
      oy = (widgetSize.height - dh) / 2;
    } else {
      dh = widgetSize.height;
      dw = widgetSize.height * fAsp;
      ox = (widgetSize.width - dw) / 2;
    }

    final double rx = (scene.dx - ox) / dw;
    final double ry = (scene.dy - oy) / dh;
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return null;

    return Offset(rx * fbW, ry * fbH);
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _manager.state == VncConnectionState.connected
                ? '${_manager.frameBufferWidth}x${_manager.frameBufferHeight}'
                : '连接中...',
          ),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _onWillPop,
          ),
          actions: [
            IconButton(
              icon: Icon(
                _enableMouseEvents ? Icons.mouse : Icons.mouse_outlined,
              ),
              tooltip: _enableMouseEvents ? '鼠标控制：开' : '鼠标控制：关',
              onPressed: () =>
                  setState(() => _enableMouseEvents = !_enableMouseEvents),
            ),
            IconButton(
              icon: const Icon(Icons.zoom_in_map_rounded),
              tooltip: '重置缩放',
              onPressed: () =>
                  _transformController.value = Matrix4.identity(),
            ),
          ],
        ),
        backgroundColor: Colors.black,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size widgetSize =
            Size(constraints.maxWidth, constraints.maxHeight);

        return Listener(
          onPointerDown: (_) => _onPointerDown(),
          onPointerUp: (_) => _onPointerUp(),
          onPointerCancel: (_) => _onPointerUp(),
          child: _VncInteractiveArea(
            transformController: _transformController,
            imageNotifier: _imageNotifier,
            fbWidth: _manager.frameBufferWidth,
            fbHeight: _manager.frameBufferHeight,
            enableMouseEvents: _enableMouseEvents,
            onPointerEvent: (pos, pressed) =>
                _handlePointer(pos, widgetSize, pressed: pressed),
            onPanEnd: () =>
                _manager.sendPointerEvent(x: 0, y: 0, button1Down: false),
          ),
        );
      },
    );
  }

  void _handlePointer(
    Offset localPosition,
    Size widgetSize, {
    required bool pressed,
  }) {
    final Offset? fb = _toFrameBufferCoords(localPosition, widgetSize);
    if (fb == null) return;
    _manager.sendPointerEvent(
      x: fb.dx.toInt(),
      y: fb.dy.toInt(),
      button1Down: pressed,
    );
  }

  // ── 触摸暂停/恢复 ─────────────────────────────────────────────────────────

  void _onPointerDown() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _activePointers++;
    if (_activePointers == 1) _manager.pauseRendering();
  }

  void _onPointerUp() {
    _activePointers = (_activePointers - 1).clamp(0, 99);
    if (_activePointers == 0) {
      _resumeTimer?.cancel();
      // 对齐到下一个 vsync 帧再恢复渲染，避免恢复时机恰好卡在帧绘制中间
      _resumeTimer = Timer(_resumeDelay, () {
        _resumeTimer = null;
        if (!mounted) return;
        // scheduleFrameCallback 确保在下一帧开始时恢复，
        // 此时手势惯性动画已经完成当前帧，不会竞争
        SchedulerBinding.instance.scheduleFrameCallback((_) {
          if (!mounted) return;
          _manager.resumeRendering();
          // 同时把最新图像推到 notifier
          _imageNotifier.value = _manager.currentImage;
        });
      });
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _VncInteractiveArea
// ─────────────────────────────────────────────────────────────────────────────

/// 独立 StatefulWidget，包裹 InteractiveViewer。
///
/// 父级 build() 重建时 Flutter element tree 复用此 State，
/// InteractiveViewer 的手势识别器和动画状态完全保留。
/// 图像更新通过 [ValueListenableBuilder] 精准重建 [RawImage]，
/// 不触碰 InteractiveViewer 层。
class _VncInteractiveArea extends StatefulWidget {
  final TransformationController transformController;
  final ValueNotifier<ui.Image?> imageNotifier;
  final int fbWidth;
  final int fbHeight;
  final bool enableMouseEvents;
  final void Function(Offset localPosition, bool pressed) onPointerEvent;
  final VoidCallback onPanEnd;

  const _VncInteractiveArea({
    required this.transformController,
    required this.imageNotifier,
    required this.fbWidth,
    required this.fbHeight,
    required this.enableMouseEvents,
    required this.onPointerEvent,
    required this.onPanEnd,
  });

  @override
  State<_VncInteractiveArea> createState() => _VncInteractiveAreaState();
}

class _VncInteractiveAreaState extends State<_VncInteractiveArea> {
  @override
  Widget build(BuildContext context) {
    final Widget imageLayer = ValueListenableBuilder<ui.Image?>(
      valueListenable: widget.imageNotifier,
      builder: (_, image, __) {
        if (image == null) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white70),
                SizedBox(height: 16),
                Text('正在等待画面...', style: TextStyle(color: Colors.white70)),
              ],
            ),
          );
        }
        return RepaintBoundary(
          child: Center(
            child: AspectRatio(
              aspectRatio: widget.fbWidth / widget.fbHeight,
              child: RawImage(
                image: image,
                fit: BoxFit.contain,
                filterQuality: Platform.isAndroid
                    ? FilterQuality.none
                    : FilterQuality.low,
              ),
            ),
          ),
        );
      },
    );

    final Widget content = widget.enableMouseEvents
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => widget.onPointerEvent(d.localPosition, true),
            onTapUp: (d) => widget.onPointerEvent(d.localPosition, false),
            onPanStart: (d) => widget.onPointerEvent(d.localPosition, true),
            onPanUpdate: (d) => widget.onPointerEvent(d.localPosition, true),
            onPanEnd: (_) => widget.onPanEnd(),
            child: imageLayer,
          )
        : imageLayer;

    return InteractiveViewer(
      transformationController: widget.transformController,
      constrained: true,
      maxScale: 10,
      minScale: 0.5,
      clipBehavior: Clip.none,
      child: content,
    );
  }
}
