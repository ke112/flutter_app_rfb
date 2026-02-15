import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'vnc_client_manager.dart';

/// VNC 远程桌面查看器页面。
///
/// 显示 VNC 服务器的帧缓冲区图像，支持双指缩放/平移，
/// 以及触摸转鼠标事件。页面关闭时自动断开连接。
class VncViewerPage extends StatefulWidget {
  /// VNC 客户端管理器，由 [VncConnectPage] 创建并传入。
  final VncClientManager manager;

  const VncViewerPage({super.key, required this.manager});

  @override
  State<VncViewerPage> createState() => _VncViewerPageState();
}

class _VncViewerPageState extends State<VncViewerPage> {
  final TransformationController _transformController = TransformationController();

  VncClientManager get _manager => widget.manager;

  /// 防止断连弹窗重复弹出。
  bool _isShowingDisconnectDialog = false;

  /// 页面是否正在退出中（防止 dispose 期间的回调冲突）。
  bool _isExiting = false;

  /// 是否将触摸事件映射为鼠标事件发送到 VNC 服务器。
  /// 设为 false 时，触摸仅用于缩放/平移查看画面，不影响远程桌面。
  /// 后期可通过 UI 开关或设置页面改为 true 以启用远程鼠标控制。
  bool _enableMouseEvents = false;

  /// ---------- 触摸暂停渲染 ----------

  /// 当前屏幕上活跃的触摸指针数量。
  int _activePointers = 0;

  /// 手指全部抬起后，延迟恢复渲染的定时器。
  Timer? _resumeTimer;

  /// 手指离开后恢复渲染的延迟时间（缩短以减少恢复等待感）。
  static const Duration _resumeDelay = Duration(milliseconds: 150);

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerUpdate);
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    // 先移除监听器，再断开连接，避免 disconnect 触发的回调导致问题
    _manager.removeListener(_onManagerUpdate);
    _manager.disconnect(silent: true);
    _manager.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _onManagerUpdate() {
    if (!mounted || _isExiting) return;

    if (_manager.state == VncConnectionState.error || _manager.state == VncConnectionState.disconnected) {
      _showDisconnectedDialog();
      return;
    }

    // 触摸交互期间（含延迟恢复等待期），跳过帧 setState，
    // 让 InteractiveViewer 对静态图做变换，保证丝滑。
    if (_activePointers > 0 || _resumeTimer != null) return;

    // 仅更新帧画面区域
    setState(() {});
  }

  void _showDisconnectedDialog() {
    if (!mounted || _isShowingDisconnectDialog || _isExiting) return;
    _isShowingDisconnectDialog = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('连接已断开'),
            content: Text(_manager.errorMessage ?? '与服务器的连接已丢失。'),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _exitPage();
                },
                child: const Text('确定'),
              ),
            ],
          ),
    ).then((_) {
      _isShowingDisconnectDialog = false;
    });
  }

  Future<bool> _onWillPop() async {
    if (_isExiting) return false;
    final confirmed = await _showDisconnectConfirmation();
    if (confirmed) {
      _exitPage();
    }
    return false; // 手动控制 pop
  }

  Future<bool> _showDisconnectConfirmation() async {
    final result = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('断开连接？'),
            content: const Text('确定要断开与远程桌面的连接吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                child: const Text('断开'),
              ),
            ],
          ),
    );
    return result == true;
  }

  /// 安全退出页面，确保不会重复退出。
  void _exitPage() {
    if (_isExiting || !mounted) return;
    _isExiting = true;
    Navigator.of(context).pop();
  }

  /// 将 Widget 局部坐标转换为帧缓冲区坐标。
  ///
  /// 考虑 [InteractiveViewer] 的变换矩阵和图像显示区域的缩放。
  Offset? _toFrameBufferCoords(Offset localPosition, Size widgetSize) {
    final int fbW = _manager.frameBufferWidth;
    final int fbH = _manager.frameBufferHeight;
    if (fbW == 0 || fbH == 0) return null;

    final Matrix4 inverseMatrix = Matrix4.inverted(_transformController.value);
    final Offset scenePoint = MatrixUtils.transformPoint(inverseMatrix, localPosition);

    final double widgetAspect = widgetSize.width / widgetSize.height;
    final double fbAspect = fbW / fbH;

    double displayWidth;
    double displayHeight;
    double offsetX = 0;
    double offsetY = 0;

    if (fbAspect > widgetAspect) {
      displayWidth = widgetSize.width;
      displayHeight = widgetSize.width / fbAspect;
      offsetY = (widgetSize.height - displayHeight) / 2;
    } else {
      displayHeight = widgetSize.height;
      displayWidth = widgetSize.height * fbAspect;
      offsetX = (widgetSize.width - displayWidth) / 2;
    }

    final double relativeX = (scenePoint.dx - offsetX) / displayWidth;
    final double relativeY = (scenePoint.dy - offsetY) / displayHeight;

    if (relativeX < 0 || relativeX > 1 || relativeY < 0 || relativeY > 1) {
      return null;
    }

    return Offset(relativeX * fbW, relativeY * fbH);
  }

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _manager.state == VncConnectionState.connected
                ? '${_manager.frameBufferWidth}x'
                    '${_manager.frameBufferHeight}'
                : '连接中...',
          ),
          centerTitle: true,
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => _onWillPop()),
          actions: [
            IconButton(
              icon: Icon(_enableMouseEvents ? Icons.mouse : Icons.mouse_outlined),
              tooltip: _enableMouseEvents ? '鼠标控制：开' : '鼠标控制：关',
              onPressed: () {
                setState(() {
                  _enableMouseEvents = !_enableMouseEvents;
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.zoom_in_map_rounded),
              tooltip: '重置缩放',
              onPressed: () {
                _transformController.value = Matrix4.identity();
              },
            ),
          ],
        ),
        backgroundColor: Colors.black,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final ui.Image? image = _manager.currentImage;

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final Size widgetSize = Size(constraints.maxWidth, constraints.maxHeight);

        final Widget imageWidget = RepaintBoundary(
          child: Center(
            child: AspectRatio(
              aspectRatio: _manager.frameBufferWidth / _manager.frameBufferHeight,
              child: RawImage(image: image, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
            ),
          ),
        );

        // 用 Listener 拦截原始指针事件，实现触摸期间暂停渲染。
        // Listener 不消费手势，不会影响 InteractiveViewer 的缩放/平移。
        return Listener(
          onPointerDown: (_) => _onPointerDown(),
          onPointerUp: (_) => _onPointerUp(),
          onPointerCancel: (_) => _onPointerUp(),
          child: InteractiveViewer(
            transformationController: _transformController,
            constrained: true,
            maxScale: 10,
            minScale: 0.5,
            // 鼠标控制关闭时，InteractiveViewer 独占手势用于缩放/平移
            // 鼠标控制开启时，内部 GestureDetector 拦截单指操作转发为鼠标事件
            child:
                _enableMouseEvents
                    ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        _handlePointer(details.localPosition, widgetSize, pressed: true);
                      },
                      onTapUp: (details) {
                        _handlePointer(details.localPosition, widgetSize, pressed: false);
                      },
                      onPanStart: (details) {
                        _handlePointer(details.localPosition, widgetSize, pressed: true);
                      },
                      onPanUpdate: (details) {
                        _handlePointer(details.localPosition, widgetSize, pressed: true);
                      },
                      onPanEnd: (details) {
                        _manager.sendPointerEvent(x: 0, y: 0, button1Down: false);
                      },
                      child: imageWidget,
                    )
                    : imageWidget,
          ),
        );
      },
    );
  }

  void _handlePointer(Offset localPosition, Size widgetSize, {required bool pressed}) {
    final Offset? fbCoords = _toFrameBufferCoords(localPosition, widgetSize);
    if (fbCoords == null) return;

    _manager.sendPointerEvent(x: fbCoords.dx.toInt(), y: fbCoords.dy.toInt(), button1Down: pressed);
  }

  // ---------- 触摸暂停/恢复渲染 ----------

  /// 手指按下：暂停渲染，取消恢复定时器。
  void _onPointerDown() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _activePointers++;

    if (_activePointers == 1) {
      // 第一根手指落下，立即暂停渲染
      _manager.pauseRendering();
    }
  }

  /// 手指抬起或取消：当所有手指离开后，启动延迟恢复定时器。
  void _onPointerUp() {
    _activePointers = (_activePointers - 1).clamp(0, 99);

    if (_activePointers == 0) {
      // 所有手指离开，延迟恢复渲染
      _resumeTimer?.cancel();
      _resumeTimer = Timer(_resumeDelay, () {
        // 关键：必须先清除定时器引用，否则 _onManagerUpdate 中
        // _resumeTimer != null 检查会永远跳过 setState，导致画面冻结。
        _resumeTimer = null;
        if (!mounted) return;
        _manager.resumeRendering();
      });
    }
  }
}
