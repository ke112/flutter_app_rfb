import 'dart:async';
import 'dart:isolate';
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

/// 在后台 Isolate 中管理帧缓冲区的像素操作。
///
/// 将 CPU 密集型的矩形像素写入和缓冲区快照复制移至独立 Isolate，
/// 避免阻塞 UI 线程导致 Android ANR。
class _FrameBufferProcessor {
  Isolate? _isolate;
  SendPort? _commandPort;
  bool _disposed = false;

  bool get isReady => _commandPort != null && !_disposed;

  Future<void> start(int width, int height) async {
    final receiver = ReceivePort();
    _isolate = await Isolate.spawn(_isolateEntry, receiver.sendPort);
    _commandPort = await receiver.first as SendPort;
    _commandPort!.send(['init', width, height]);
  }

  /// 发送矩形更新到 Isolate（非阻塞 fire-and-forget）。
  ///
  /// 每个矩形为一个 List：
  /// - Raw:      [false, x, y, w, h, Uint8List bytes]
  /// - CopyRect: [true,  x, y, w, h, sourceX, sourceY]
  void applyRects(List<List<Object>> rects) {
    _commandPort?.send(['rects', rects]);
  }

  /// 请求当前帧缓冲区快照，用于图像解码。
  ///
  /// 使用 [TransferableTypedData] 实现零拷贝跨 Isolate 传输。
  Future<Uint8List?> snapshot() async {
    if (!isReady) return null;
    final receiver = ReceivePort();
    try {
      _commandPort!.send(['snap', receiver.sendPort]);
      final result = await receiver.first.timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List();
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      receiver.close();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _commandPort?.send(['exit']);
    } catch (_) {}
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
  }

  // --------------- Isolate 入口及像素操作 ---------------

  static void _isolateEntry(SendPort mainPort) {
    final port = ReceivePort();
    mainPort.send(port.sendPort);

    Uint8List? fb;
    int fbW = 0;
    int fbH = 0;

    port.listen((msg) {
      if (msg is! List || msg.isEmpty) return;
      switch (msg[0]) {
        case 'init':
          fbW = msg[1] as int;
          fbH = msg[2] as int;
          fb = Uint8List(fbW * fbH * 4);

        case 'rects':
          if (fb == null) return;
          final rects = msg[1] as List;
          for (final r in rects) {
            final rect = r as List;
            if (rect[0] as bool) {
              _applyCopyRect(fb!, fbW, rect);
            } else {
              _applyRawRect(fb!, fbW, fbH, rect);
            }
          }

        case 'snap':
          final replyPort = msg[1] as SendPort;
          if (fb != null) {
            replyPort.send(TransferableTypedData.fromList([Uint8List.fromList(fb!)]));
          } else {
            replyPort.send(null);
          }

        case 'exit':
          fb = null;
          port.close();
      }
    });
  }

  static void _applyRawRect(Uint8List fb, int fbW, int fbH, List rect) {
    final int x = rect[1] as int;
    final int y = rect[2] as int;
    final int rw = rect[3] as int;
    final int rh = rect[4] as int;
    final Uint8List src = rect[5] as Uint8List;
    final int cw = rw.clamp(0, fbW - x);
    final int ch = rh.clamp(0, fbH - y);
    final int rowBytes = cw * 4;

    for (int row = 0; row < ch; row++) {
      final int sOff = row * rw * 4;
      final int dOff = ((y + row) * fbW + x) * 4;
      if (sOff + rowBytes <= src.length && dOff + rowBytes <= fb.length) {
        fb.setRange(dOff, dOff + rowBytes, src, sOff);
      }
    }
  }

  static void _applyCopyRect(Uint8List fb, int fbW, List rect) {
    final int x = rect[1] as int;
    final int y = rect[2] as int;
    final int rw = rect[3] as int;
    final int rh = rect[4] as int;
    final int sx = rect[5] as int;
    final int sy = rect[6] as int;
    final int rowBytes = rw * 4;
    final temp = Uint8List(rw * rh * 4);

    for (int row = 0; row < rh; row++) {
      final sOff = ((sy + row) * fbW + sx) * 4;
      final tOff = row * rowBytes;
      if (sOff + rowBytes <= fb.length && tOff + rowBytes <= temp.length) {
        temp.setRange(tOff, tOff + rowBytes, fb, sOff);
      }
    }
    for (int row = 0; row < rh; row++) {
      final dOff = ((y + row) * fbW + x) * 4;
      final tOff = row * rowBytes;
      if (dOff + rowBytes <= fb.length && tOff + rowBytes <= temp.length) {
        fb.setRange(dOff, dOff + rowBytes, temp, tOff);
      }
    }
  }
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

  /// 后台 Isolate 帧缓冲区处理器。
  _FrameBufferProcessor _fbProcessor = _FrameBufferProcessor();

  /// 是否已被 dispose，防止 dispose 后继续操作。
  bool _isDisposed = false;

  /// 是否正在处理帧数据（防止并发处理积压）。
  bool _isProcessingFrame = false;

  /// 是否有待处理的帧更新（节流：处理期间来的更新合并为一次）。
  bool _hasPendingUpdate = false;

  /// 渲染是否已暂停（触摸交互期间暂停，以避免 setState 抖动）。
  bool _renderingPaused = false;

  /// 暂停期间缓冲区是否有新数据写入（恢复时需要解码）。
  bool _dirtyWhilePaused = false;

  /// 帧率节流：最小帧间隔（约 20fps，降低移动设备 CPU 负载）。
  static const Duration _minFrameInterval = Duration(milliseconds: 50);
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

  /// 暂停渲染（触摸开始时调用）。
  ///
  /// 数据仍然发送到后台 Isolate 写入帧缓冲区，但不解码为 Image、不通知 UI。
  void pauseRendering() {
    _renderingPaused = true;
    _dirtyWhilePaused = false;
  }

  /// 恢复渲染（触摸结束一段时间后调用）。
  ///
  /// 如果暂停期间有新数据，立即从 Isolate 获取快照并解码刷新画面；
  /// 否则直接请求下一帧以重启更新循环。
  void resumeRendering() {
    if (!_renderingPaused) return;
    _renderingPaused = false;
    if (_dirtyWhilePaused) {
      _dirtyWhilePaused = false;
      _decodeAndNotify();
    } else {
      _client?.requestUpdate();
    }
  }

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
          _logger.info(
            'Framebuffer size: '
            '${_frameBufferWidth}x$_frameBufferHeight',
          );
        },
      );

      _fbProcessor = _FrameBufferProcessor();
      await _fbProcessor.start(_frameBufferWidth, _frameBufferHeight);

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

  /// 处理一次帧缓冲区更新。
  ///
  /// 矩形像素数据序列化后发送到后台 Isolate 处理，
  /// 主线程只做轻量级数据封装，不执行任何像素操作。
  void _onFrameBufferUpdate(RemoteFrameBufferClientUpdate update) {
    if (_isDisposed || !_fbProcessor.isReady) return;

    final List<List<Object>> serializedRects = [];
    for (final rectangle in update.rectangles) {
      rectangle.encodingType.when(
        copyRect: () {
          if (rectangle.byteData.lengthInBytes < 4) return;
          serializedRects.add([
            true,
            rectangle.x,
            rectangle.y,
            rectangle.width,
            rectangle.height,
            rectangle.byteData.getUint16(0),
            rectangle.byteData.getUint16(2),
          ]);
        },
        raw: () {
          serializedRects.add([
            false,
            rectangle.x,
            rectangle.y,
            rectangle.width,
            rectangle.height,
            Uint8List.fromList(
              rectangle.byteData.buffer.asUint8List(rectangle.byteData.offsetInBytes, rectangle.byteData.lengthInBytes),
            ),
          ]);
        },
        unsupported: (final ByteData bytes) {},
      );
    }

    if (serializedRects.isEmpty) {
      _client?.requestUpdate();
      return;
    }

    _fbProcessor.applyRects(serializedRects);

    if (_renderingPaused) {
      _dirtyWhilePaused = true;
      _client?.requestUpdate();
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastFrameTime) < _minFrameInterval) {
      if (!_hasPendingUpdate) {
        _hasPendingUpdate = true;
        Future.delayed(_minFrameInterval, () {
          if (_isDisposed) return;
          _hasPendingUpdate = false;
          if (_renderingPaused) {
            _dirtyWhilePaused = true;
            _client?.requestUpdate();
            return;
          }
          _decodeAndNotify();
        });
      }
      return;
    }

    _decodeAndNotify();
  }

  /// 从后台 Isolate 获取帧缓冲区快照，解码为 Flutter Image 并通知 UI。
  void _decodeAndNotify() {
    if (_isDisposed || _isProcessingFrame || !_fbProcessor.isReady) return;

    _isProcessingFrame = true;
    _lastFrameTime = DateTime.now();

    _fbProcessor
        .snapshot()
        .then((Uint8List? buffer) {
          if (_isDisposed || buffer == null) {
            _isProcessingFrame = false;
            _client?.requestUpdate();
            return;
          }

          ui.decodeImageFromPixels(buffer, _frameBufferWidth, _frameBufferHeight, ui.PixelFormat.bgra8888, (
            ui.Image image,
          ) {
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
          });
        })
        .catchError((Object error) {
          _isProcessingFrame = false;
          _logger.severe('Frame decode error: $error');
          _client?.requestUpdate();
        });
  }

  /// 清理所有资源。
  Future<void> _cleanup() async {
    await _updateSubscription?.cancel();
    _updateSubscription = null;

    await _client?.close();
    _client = null;

    _fbProcessor.dispose();
    _frameBufferWidth = 0;
    _frameBufferHeight = 0;
  }
}
