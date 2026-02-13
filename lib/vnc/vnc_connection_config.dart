/// VNC 连接配置模型。
///
/// 封装连接 VNC 服务器所需的所有参数。
/// 当前支持手动输入方式，预留 [fromApiResponse] 供未来
/// Token 模式下从后端 API 获取连接信息。
class VncConnectionConfig {
  /// VNC 服务器主机地址。
  final String host;

  /// VNC 服务器 TCP 端口，默认 5900。
  final int port;

  /// VNC Authentication 密码，为空则使用 None 认证。
  final String? password;

  const VncConnectionConfig({required this.host, this.port = 5900, this.password});

  /// 从后端 API 响应构造连接配置。
  ///
  /// 未来 Token 模式下，客户端通过 Token 调用后端 API，
  /// 后端返回 VNC 连接信息（host、port、password），
  /// 客户端使用该信息直连 VNC 服务器。
  factory VncConnectionConfig.fromApiResponse(Map<String, dynamic> json) {
    return VncConnectionConfig(
      host: json['host'] as String,
      port: json['port'] as int? ?? 5900,
      password: json['password'] as String?,
    );
  }

  @override
  String toString() =>
      'VncConnectionConfig(host: $host, port: $port, '
      'password: ${password != null ? "***" : "null"})';
}
