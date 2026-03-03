import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:dart_rfb/dart_rfb.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'vnc_connection_config.dart';

/// VNC 客户端连接状态。
enum VncConnectionState { disconnected, connecting, connected, error }

// ─────────────────────────────────────────────────────────────────────────────
// 后台像素处理 Isolate（仅做像素合成，不碰 socket）
// ─────────────────────────────────────────────────────────────────────────────

enum _Cmd { init, rects, snap, exit }

class _FrameBufferProcessor {
  Isolate? _isolate;
  SendPort? _commandPort;
  bool _disposed = false;

  bool get isReady => _commandPort != null && !_disposed;

  Future<void> start(int width, int height) async {
    final receiver = ReceivePort();
    _isolate = await Isolate.spawn(_isolateEntry, receiver.sendPort);
    _commandPort = await receiver.first as SendPort;
    _commandPort!.send([_Cmd.init, width, height]);
  }

  void applyRects(List<List<Object>> rects) {
    _commandPort?.send([_Cmd.rects, rects]);
  }

  Future<Uint8List?> snapshot() async {
    if (!isReady) return null;
    final receiver = ReceivePort();
    try {
      _commandPort!.send([_Cmd.snap, receiver.sendPort]);
      final result = await receiver.first.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () => null,
      );
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
      _commandPort?.send([_Cmd.exit]);
    } catch (_) {}
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
  }

  static void _isolateEntry(SendPort mainPort) {
    final port = ReceivePort();
    mainPort.send(port.sendPort);

    Uint8List? fb;
    int fbW = 0;
    int fbH = 0;

    port.listen((msg) {
      if (msg is! List || msg.isEmpty) return;
      switch (msg[0] as _Cmd) {
        case _Cmd.init:
          fbW = msg[1] as int;
          fbH = msg[2] as int;
          fb = Uint8List(fbW * fbH * 4);

        case _Cmd.rects:
          if (fb == null) return;
          for (final r in msg[1] as List) {
            final rect = r as List;
            if (rect[0] as bool) {
              _applyCopyRect(fb!, fbW, rect);
            } else {
              _applyRawRect(fb!, fbW, fbH, rect);
            }
          }

        case _Cmd.snap:
          final replyPort = msg[1] as SendPort;
          if (fb != null) {
            // 完整拷贝后再传输，避免 data race
            replyPort.send(
              TransferableTypedData.fromList([Uint8List.fromList(fb!)]),
            );
          } else {
            replyPort.send(null);
          }

        case _Cmd.exit:
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

// ─────────────────────────────────────────────────────────────────────────────
// VncClientManager
// ─────────────────────────────────────────────────────────────────────────────

class VncClientManager extends ChangeNotifier {
  static final Logger _logger = Logger('VncClientManager');

  RemoteFrameBufferClient? _client;
  StreamSubscription<RemoteFrameBufferClientUpdate>? _updateSubscription;

  VncConnectionState _state = VncConnectionState.disconnected;
  String? _errorMessage;
  ui.Image? _currentImage;
  int _frameBufferWidth = 0;
  int _frameBufferHeight = 0;

  _FrameBufferProcessor _fbProcessor = _FrameBufferProcessor();

  bool _isDisposed = false;
  bool _isProcessingFrame = false;
  bool _hasPendingUpdate = false;
  Timer? _pendingDelayTimer;

  /// 触摸期间为 true：
  /// - _onFrameBufferUpdate 立即返回，不序列化矩形
  /// - 不向服务器发 requestUpdate → 服务器停止推帧 → 主线程零帧回调
  bool _renderingPaused = false;

  /// Android ~5fps（200ms）；iOS ~15fps（66ms）。
  static final Duration _minFrameInterval = Duration(
    milliseconds: Platform.isAndroid ? 200 : 66,
  );
  DateTime _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);

  VncConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  ui.Image? get currentImage => _currentImage;
  int get frameBufferWidth => _frameBufferWidth;
  int get frameBufferHeight => _frameBufferHeight;

  // ── 渲染暂停/恢复 ─────────────────────────────────────────────────────────

  void pauseRendering() {
    if (_renderingPaused) return;
    _renderingPaused = true;
    _pendingDelayTimer?.cancel();
    _pendingDelayTimer = null;
    _hasPendingUpdate = false;
  }

  void resumeRendering() {
    if (!_renderingPaused) return;
    _renderingPaused = false;
    _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);
    _client?.requestUpdate();
  }

  // ── 连接 ──────────────────────────────────────────────────────────────────

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
      _logger.info('Connected');

      _client!.config.match(
        () => throw Exception('Server config not available after connect'),
        (final Config cfg) {
          _frameBufferWidth = cfg.frameBufferWidth;
          _frameBufferHeight = cfg.frameBufferHeight;
          _logger.info('Framebuffer: ${_frameBufferWidth}x$_frameBufferHeight');
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

  Future<void> disconnect({bool silent = false}) async {
    _logger.info('Disconnecting');
    await _cleanup();
    _state = VncConnectionState.disconnected;
    _errorMessage = null;
    if (!silent && !_isDisposed) notifyListeners();
  }

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
    _isDisposed = true;
    _cleanup();
    _currentImage = null;
    super.dispose();
  }

  // ── 帧监听 ────────────────────────────────────────────────────────────────

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

  void _onFrameBufferUpdate(RemoteFrameBufferClientUpdate update) {
    if (_isDisposed || !_fbProcessor.isReady) return;

    // 触摸期间：立即返回，不处理任何数据，不请求下一帧
    // → 服务器不再推送 → 主线程完全空闲
    if (_renderingPaused) return;

    final List<List<Object>> rects = [];
    for (final rectangle in update.rectangles) {
      rectangle.encodingType.when(
        copyRect: () {
          if (rectangle.byteData.lengthInBytes < 4) return;
          rects.add([
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
          rects.add([
            false,
            rectangle.x,
            rectangle.y,
            rectangle.width,
            rectangle.height,
            Uint8List.fromList(
              rectangle.byteData.buffer.asUint8List(
                rectangle.byteData.offsetInBytes,
                rectangle.byteData.lengthInBytes,
              ),
            ),
          ]);
        },
        unsupported: (_) {},
      );
    }

    if (rects.isEmpty) {
      _client?.requestUpdate();
      return;
    }

    // 像素写入交给后台 Isolate，主线程立即返回
    _fbProcessor.applyRects(rects);

    final elapsed = DateTime.now().difference(_lastFrameTime);
    if (elapsed < _minFrameInterval) {
      if (!_hasPendingUpdate) {
        _hasPendingUpdate = true;
        _pendingDelayTimer?.cancel();
        _pendingDelayTimer = Timer(_minFrameInterval - elapsed, () {
          _pendingDelayTimer = null;
          if (_isDisposed || _renderingPaused) return;
          _hasPendingUpdate = false;
          _decodeAndNotify();
        });
      }
      return;
    }

    _decodeAndNotify();
  }

  void _decodeAndNotify() {
    if (_isDisposed || _isProcessingFrame || !_fbProcessor.isReady) return;

    _isProcessingFrame = true;
    _lastFrameTime = DateTime.now();

    _fbProcessor.snapshot().then((Uint8List? buffer) async {
      if (_isDisposed || buffer == null) {
        _isProcessingFrame = false;
        if (!_renderingPaused) _client?.requestUpdate();
        return;
      }

      ui.Image? image;
      try {
        // raster 线程解码，不占主线程
        final immutable = await ui.ImmutableBuffer.fromUint8List(buffer);
        final descriptor = ui.ImageDescriptor.raw(
          immutable,
          width: _frameBufferWidth,
          height: _frameBufferHeight,
          pixelFormat: ui.PixelFormat.bgra8888,
        );
        final codec = await descriptor.instantiateCodec();
        final frame = await codec.getNextFrame();
        image = frame.image;
        descriptor.dispose();
        immutable.dispose();
      } catch (e) {
        _logger.severe('Frame decode error: $e');
      }

      _isProcessingFrame = false;

      if (_isDisposed) {
        image?.dispose();
        return;
      }

      if (image != null) {
        _currentImage?.dispose();
        _currentImage = image;
        notifyListeners();
      }

      if (!_renderingPaused) _client?.requestUpdate();
    }).catchError((Object error) {
      _isProcessingFrame = false;
      _logger.severe('Frame pipeline error: $error');
      if (!_renderingPaused) _client?.requestUpdate();
    });
  }

  // ── 清理 ──────────────────────────────────────────────────────────────────

  Future<void> _cleanup() async {
    _renderingPaused = false;
    _pendingDelayTimer?.cancel();
    _pendingDelayTimer = null;
    await _updateSubscription?.cancel();
    _updateSubscription = null;
    await _client?.close();
    _client = null;
    _fbProcessor.dispose();
    _frameBufferWidth = 0;
    _frameBufferHeight = 0;
  }
}
