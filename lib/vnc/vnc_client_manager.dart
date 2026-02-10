import 'dart:async';
import 'dart:typed_data';
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
  ByteData? _frameBuffer;

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
    if (_state == VncConnectionState.connecting ||
        _state == VncConnectionState.connected) {
      return;
    }

    _state = VncConnectionState.connecting;
    _errorMessage = null;
    notifyListeners();

    try {
      _client = RemoteFrameBufferClient();

      _logger.info('Connecting to ${config.host}:${config.port}');

      await _client!.connect(
        hostname: config.host,
        port: config.port,
        password: config.password,
      );

      _logger.info('Connected successfully');

      final clientConfig = _client!.config;
      clientConfig.match(
        () {
          throw Exception('Server config not available after connect');
        },
        (final Config cfg) {
          _frameBufferWidth = cfg.frameBufferWidth;
          _frameBufferHeight = cfg.frameBufferHeight;
          _frameBuffer = ByteData(
            _frameBufferWidth * _frameBufferHeight * 4,
          );
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
  Future<void> disconnect() async {
    _logger.info('Disconnecting');
    await _cleanup();
    _state = VncConnectionState.disconnected;
    _errorMessage = null;
    notifyListeners();
  }

  /// 发送鼠标/触摸指针事件到 VNC 服务器。
  ///
  /// [x] 和 [y] 是帧缓冲区坐标（非 Widget 坐标）。
  /// [button1Down] 对应鼠标左键/触摸按下。
  void sendPointerEvent({
    required int x,
    required int y,
    bool button1Down = false,
  }) {
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
        _logger.severe('Update stream error: $error');
        _state = VncConnectionState.error;
        _errorMessage = error.toString();
        notifyListeners();
      },
      onDone: () {
        _logger.info('Update stream closed');
        if (_state == VncConnectionState.connected) {
          _state = VncConnectionState.disconnected;
          notifyListeners();
        }
      },
    );

    _client!.requestUpdate();
  }

  /// 处理一次帧缓冲区更新。
  void _onFrameBufferUpdate(RemoteFrameBufferClientUpdate update) {
    final ByteData? fb = _frameBuffer;
    if (fb == null) return;

    for (final rectangle in update.rectangles) {
      rectangle.encodingType.when(
        copyRect: () => _applyCopyRect(fb, rectangle),
        raw: () => _applyRawRect(fb, rectangle),
        unsupported: (final ByteData bytes) {},
      );
    }

    _decodeAndNotify(fb);
  }

  /// 将 Raw 编码的矩形像素数据写入帧缓冲区。
  void _applyRawRect(
    ByteData fb,
    RemoteFrameBufferClientUpdateRectangle rect,
  ) {
    for (int y = 0; y < rect.height; y++) {
      for (int x = 0; x < rect.width; x++) {
        final int fbX = rect.x + x;
        final int fbY = rect.y + y;
        if (fbX >= _frameBufferWidth || fbY >= _frameBufferHeight) {
          continue;
        }
        final int srcOffset = (y * rect.width + x) * 4;
        final int dstOffset =
            (fbY * _frameBufferWidth + fbX) * 4;
        if (srcOffset + 3 < rect.byteData.lengthInBytes) {
          fb.setUint32(dstOffset, rect.byteData.getUint32(srcOffset));
        }
      }
    }
  }

  /// 将 CopyRect 编码的矩形数据写入帧缓冲区。
  void _applyCopyRect(
    ByteData fb,
    RemoteFrameBufferClientUpdateRectangle rect,
  ) {
    if (rect.byteData.lengthInBytes < 4) return;

    final int sourceX = rect.byteData.getUint16(0);
    final int sourceY = rect.byteData.getUint16(2);

    final BytesBuilder bytesBuilder = BytesBuilder();
    for (int row = 0; row < rect.height; row++) {
      for (int col = 0; col < rect.width; col++) {
        final int srcOffset =
            ((sourceY + row) * _frameBufferWidth + sourceX + col) * 4;
        if (srcOffset + 3 < fb.lengthInBytes) {
          bytesBuilder.add(
            fb.buffer.asUint8List(srcOffset, 4),
          );
        }
      }
    }

    final Uint8List copiedData = bytesBuilder.toBytes();
    final ByteData copiedByteData = ByteData.sublistView(copiedData);

    final rawRect = RemoteFrameBufferClientUpdateRectangle(
      byteData: copiedByteData,
      encodingType: const RemoteFrameBufferEncodingType.raw(),
      height: rect.height,
      width: rect.width,
      x: rect.x,
      y: rect.y,
    );
    _applyRawRect(fb, rawRect);
  }

  /// 将帧缓冲区 ByteData 解码为 Flutter Image 并通知 UI。
  void _decodeAndNotify(ByteData fb) {
    ui.decodeImageFromPixels(
      fb.buffer.asUint8List(),
      _frameBufferWidth,
      _frameBufferHeight,
      ui.PixelFormat.bgra8888,
      (ui.Image image) {
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
