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
  final TransformationController _transformController =
      TransformationController();

  VncClientManager get _manager => widget.manager;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerUpdate);
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerUpdate);
    _manager.disconnect();
    _manager.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _onManagerUpdate() {
    if (!mounted) return;

    if (_manager.state == VncConnectionState.error ||
        _manager.state == VncConnectionState.disconnected) {
      _showDisconnectedDialog();
      return;
    }

    setState(() {});
  }

  void _showDisconnectedDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Disconnected'),
        content: Text(
          _manager.errorMessage ?? 'Connection lost.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _onDisconnectPressed() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text(
          'Are you sure you want to disconnect?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 将 Widget 局部坐标转换为帧缓冲区坐标。
  ///
  /// 考虑 [InteractiveViewer] 的变换矩阵和图像显示区域的缩放。
  Offset? _toFrameBufferCoords(
    Offset localPosition,
    Size widgetSize,
  ) {
    final int fbW = _manager.frameBufferWidth;
    final int fbH = _manager.frameBufferHeight;
    if (fbW == 0 || fbH == 0) return null;

    final Matrix4 inverseMatrix =
        Matrix4.inverted(_transformController.value);
    final Offset scenePoint = MatrixUtils.transformPoint(
      inverseMatrix,
      localPosition,
    );

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

    final double relativeX =
        (scenePoint.dx - offsetX) / displayWidth;
    final double relativeY =
        (scenePoint.dy - offsetY) / displayHeight;

    if (relativeX < 0 ||
        relativeX > 1 ||
        relativeY < 0 ||
        relativeY > 1) {
      return null;
    }

    return Offset(relativeX * fbW, relativeY * fbH);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _manager.state == VncConnectionState.connected
              ? '${_manager.frameBufferWidth}x'
                  '${_manager.frameBufferHeight}'
              : 'Connecting...',
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _onDisconnectPressed,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_in_map_rounded),
            tooltip: 'Reset zoom',
            onPressed: () {
              _transformController.value = Matrix4.identity();
            },
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: _buildBody(),
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
            Text(
              'Waiting for framebuffer...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final Size widgetSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );

        return InteractiveViewer(
          transformationController: _transformController,
          constrained: true,
          maxScale: 10,
          minScale: 0.5,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              _handlePointer(
                details.localPosition,
                widgetSize,
                pressed: true,
              );
            },
            onTapUp: (details) {
              _handlePointer(
                details.localPosition,
                widgetSize,
                pressed: false,
              );
            },
            onPanStart: (details) {
              _handlePointer(
                details.localPosition,
                widgetSize,
                pressed: true,
              );
            },
            onPanUpdate: (details) {
              _handlePointer(
                details.localPosition,
                widgetSize,
                pressed: true,
              );
            },
            onPanEnd: (details) {
              _manager.sendPointerEvent(
                x: 0,
                y: 0,
                button1Down: false,
              );
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: _manager.frameBufferWidth /
                    _manager.frameBufferHeight,
                child: RawImage(
                  image: image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
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
    final Offset? fbCoords = _toFrameBufferCoords(
      localPosition,
      widgetSize,
    );
    if (fbCoords == null) return;

    _manager.sendPointerEvent(
      x: fbCoords.dx.toInt(),
      y: fbCoords.dy.toInt(),
      button1Down: pressed,
    );
  }
}
