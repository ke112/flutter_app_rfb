import 'dart:async';
import 'dart:ui' as ui;

import 'package:dart_rfb/dart_rfb.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'vnc_connection_config.dart';

/// VNC 客户端连接状态。
enum VncConnectionState {
  /// 未连接。
  disconnected,

  /// 正在连接中。
  connecting,

  /// 已连接并正在接收帧数据。
  connected,

  /// 连接过程中或连接后发生错误。
  error,
}

/// 单个矩形更新数据。
class _RectUpdateData {
  final Uint8List byteData;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool isCopyRect;
  final int sourceX;
  final int sourceY;

  _RectUpdateData({
    required this.byteData,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.isCopyRect = false,
    this.sourceX = 0,
    this.sourceY = 0,
  });
}

/// VNC 客户端核心管理器。
///
/// 封装 [RemoteFrameBufferClient] 的连接生命周期、帧缓冲区管理
/// 和触摸事件转发。通过 [ChangeNotifier] 通知 UI 层状态变化。
class VncClientManager extends ChangeNotifier {
  static final Logger _logger = Logger('VncClientManager');

  RemoteFrameBufferClient? _client;
  StreamSubscription<RemoteFrameBufferClientUpdate>? _updateSubscription;

  VncConnectionState _state = VncConnectionState.disconnected;
  String? _errorMessage;
  ui.Image? _currentImage;
  int _frameBufferWidth = 0;
  int _frameBufferHeight = 0;
  Uint8List? _frameBuffer;

  /// 是否已被 dispose，防止 dispose 后继续操作。
  bool _isDisposed = false;

  /// 是否正在处理帧数据（防止并发处理积压）。
  bool _isProcessingFrame = false;

  /// 是否有待处理的帧更新（节流：处理期间来的更新合并为一次）。
  bool _hasPendingUpdate = false;

  /// 帧率节流：最小帧间隔（约 30fps）。
  static const Duration _minFrameInterval = Duration(milliseconds: 33);
  DateTime _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前连接状态。
  VncConnectionState get state => _state;

  /// 错误信息，仅在 [state] 为 [VncConnectionState.error] 时有值。
  String? get errorMessage => _errorMessage;

  /// 当前帧缓冲区渲染的 Flutter Image，可能为 null。
  ui.Image? get currentImage => _currentImage;

  /// 帧缓冲区宽度（像素）。
  int get frameBufferWidth => _frameBufferWidth;

  /// 帧缓冲区高度（像素）。
  int get frameBufferHeight => _frameBufferHeight;

  /// 连接到 VNC 服务器。
  ///
  /// 连接成功后自动开始接收帧更新。
  Future<void> connect(VncConnectionConfig config) async {
    if (_state == VncConnectionState.connecting || _state == VncConnectionState.connected) {
      return;
    }

    _state = VncConnectionState.connecting;
    _errorMessage = null;
    notifyListeners();

    try {
      _client = RemoteFrameBufferClient();

      _logger.info('Connecting to ${config.host}:${config.port}');

      await _client!.connect(hostname: config.host, port: config.port, password: config.password);

      _logger.info('Connected successfully');

      final clientConfig = _client!.config;
      clientConfig.match(
        () {
          throw Exception('Server config not available after connect');
        },
        (final Config cfg) {
          _frameBufferWidth = cfg.frameBufferWidth;
          _frameBufferHeight = cfg.frameBufferHeight;
          _frameBuffer = Uint8List(_frameBufferWidth * _frameBufferHeight * 4);
          _logger.info(
            'Framebuffer size: '
            '${_frameBufferWidth}x$_frameBufferHeight',
          );
        },
      );

      _state = VncConnectionState.connected;
      notifyListeners();

      _startListening();
    } catch (e) {
      _logger.severe('Connection failed: $e');
      _state = VncConnectionState.error;
      _errorMessage = e.toString();
      notifyListeners();
      await _cleanup();
    }
  }

  /// 断开连接并释放资源。
  ///
  /// [silent] 为 true 时不触发 notifyListeners（用于 dispose 场景）。
  Future<void> disconnect({bool silent = false}) async {
    _logger.info('Disconnecting');
    await _cleanup();
    _state = VncConnectionState.disconnected;
    _errorMessage = null;
    if (!silent && !_isDisposed) {
      notifyListeners();
    }
  }

  /// 发送鼠标/触摸指针事件到 VNC 服务器。
  ///
  /// [x] 和 [y] 是帧缓冲区坐标（非 Widget 坐标）。
  /// [button1Down] 对应鼠标左键/触摸按下。
  void sendPointerEvent({required int x, required int y, bool button1Down = false}) {
    _client?.sendPointerEvent(
      pointerEvent: RemoteFrameBufferClientPointerEvent(
        button1Down: button1Down,
        button2Down: false,
        button3Down: false,
        button4Down: false,
        button5Down: false,
        button6Down: false,
        button7Down: false,
        button8Down: false,
        x: x.clamp(0, _frameBufferWidth - 1),
        y: y.clamp(0, _frameBufferHeight - 1),
      ),
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cleanup();
    _currentImage?.dispose();
    _currentImage = null;
    super.dispose();
  }

  /// 开始监听帧缓冲区更新流。
  void _startListening() {
    _client!.handleIncomingMessages();

    _updateSubscription = _client!.updateStream.listen(
      _onFrameBufferUpdate,
      onError: (Object error) {
        if (_isDisposed) return;
        _logger.severe('Update stream error: $error');
        _state = VncConnectionState.error;
        _errorMessage = error.toString();
        notifyListeners();
      },
      onDone: () {
        if (_isDisposed) return;
        _logger.info('Update stream closed');
        if (_state == VncConnectionState.connected) {
          _state = VncConnectionState.disconnected;
          notifyListeners();
        }
      },
    );

    _client!.requestUpdate();
  }

  /// 处理一次帧缓冲区更新（带节流和并发保护）。
  void _onFrameBufferUpdate(RemoteFrameBufferClientUpdate update) {
    if (_isDisposed) return;

    final Uint8List? fb = _frameBuffer;
    if (fb == null) return;

    // 收集矩形更新数据
    final List<_RectUpdateData> rectDataList = [];
    for (final rectangle in update.rectangles) {
      rectangle.encodingType.when(
        copyRect: () {
          if (rectangle.byteData.lengthInBytes < 4) return;
          rectDataList.add(
            _RectUpdateData(
              byteData: Uint8List.fromList(
                rectangle.byteData.buffer.asUint8List(
                  rectangle.byteData.offsetInBytes,
                  rectangle.byteData.lengthInBytes,
                ),
              ),
              x: rectangle.x,
              y: rectangle.y,
              width: rectangle.width,
              height: rectangle.height,
              isCopyRect: true,
              sourceX: rectangle.byteData.getUint16(0),
              sourceY: rectangle.byteData.getUint16(2),
            ),
          );
        },
        raw: () {
          rectDataList.add(
            _RectUpdateData(
              byteData: Uint8List.fromList(
                rectangle.byteData.buffer.asUint8List(
                  rectangle.byteData.offsetInBytes,
                  rectangle.byteData.lengthInBytes,
                ),
              ),
              x: rectangle.x,
              y: rectangle.y,
              width: rectangle.width,
              height: rectangle.height,
            ),
          );
        },
        unsupported: (final ByteData bytes) {},
      );
    }

    if (rectDataList.isEmpty) {
      _client?.requestUpdate();
      return;
    }

    // 先在主线程快速应用像素更新到缓冲区（小更新时更快）
    for (final rect in rectDataList) {
      if (rect.isCopyRect) {
        _applyCopyRectFast(fb, rect);
      } else {
        _applyRawRectFast(fb, rect);
      }
    }

    // 帧率节流
    final now = DateTime.now();
    if (now.difference(_lastFrameTime) < _minFrameInterval) {
      if (!_hasPendingUpdate) {
        _hasPendingUpdate = true;
        Future.delayed(_minFrameInterval, () {
          if (_isDisposed) return;
          _hasPendingUpdate = false;
          _decodeAndNotify();
        });
      }
      return;
    }

    _decodeAndNotify();
  }

  /// 快速 Raw 矩形应用（按行批量复制，替代逐像素操作）。
  void _applyRawRectFast(Uint8List fb, _RectUpdateData rect) {
    final Uint8List src = rect.byteData;
    final int copyWidth = rect.width.clamp(0, _frameBufferWidth - rect.x);
    final int copyHeight = rect.height.clamp(0, _frameBufferHeight - rect.y);
    final int bytesPerRow = copyWidth * 4;

    for (int y = 0; y < copyHeight; y++) {
      final int srcRowStart = y * rect.width * 4;
      final int dstRowStart = ((rect.y + y) * _frameBufferWidth + rect.x) * 4;

      if (srcRowStart + bytesPerRow <= src.length && dstRowStart + bytesPerRow <= fb.length) {
        fb.setRange(dstRowStart, dstRowStart + bytesPerRow, src, srcRowStart);
      }
    }
  }

  /// 快速 CopyRect 应用（按行批量复制）。
  void _applyCopyRectFast(Uint8List fb, _RectUpdateData rect) {
    final int sourceX = rect.sourceX;
    final int sourceY = rect.sourceY;
    final int rowBytes = rect.width * 4;
    final Uint8List tempBuf = Uint8List(rect.width * rect.height * 4);

    for (int row = 0; row < rect.height; row++) {
      final int srcOffset = ((sourceY + row) * _frameBufferWidth + sourceX) * 4;
      final int tmpOffset = row * rowBytes;
      if (srcOffset + rowBytes <= fb.length && tmpOffset + rowBytes <= tempBuf.length) {
        tempBuf.setRange(tmpOffset, tmpOffset + rowBytes, fb, srcOffset);
      }
    }

    for (int row = 0; row < rect.height; row++) {
      final int dstOffset = ((rect.y + row) * _frameBufferWidth + rect.x) * 4;
      final int tmpOffset = row * rowBytes;
      if (dstOffset + rowBytes <= fb.length && tmpOffset + rowBytes <= tempBuf.length) {
        fb.setRange(dstOffset, dstOffset + rowBytes, tempBuf, tmpOffset);
      }
    }
  }

  /// 将帧缓冲区解码为 Flutter Image 并通知 UI（带并发保护）。
  void _decodeAndNotify() {
    if (_isDisposed || _isProcessingFrame) return;

    final Uint8List? fb = _frameBuffer;
    if (fb == null) return;

    _isProcessingFrame = true;
    _lastFrameTime = DateTime.now();

    ui.decodeImageFromPixels(
      Uint8List.fromList(fb), // 传递副本，避免解码期间被修改
      _frameBufferWidth,
      _frameBufferHeight,
      ui.PixelFormat.bgra8888,
      (ui.Image image) {
        _isProcessingFrame = false;

        if (_isDisposed) {
          image.dispose();
          return;
        }

        final ui.Image? oldImage = _currentImage;
        _currentImage = image;
        notifyListeners();
        oldImage?.dispose();

        _client?.requestUpdate();
      },
    );
  }

  /// 清理所有资源。
  Future<void> _cleanup() async {
    await _updateSubscription?.cancel();
    _updateSubscription = null;

    await _client?.close();
    _client = null;

    _frameBuffer = null;
    _frameBufferWidth = 0;
    _frameBufferHeight = 0;
  }
}
