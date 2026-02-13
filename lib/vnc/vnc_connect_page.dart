import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vnc_client_manager.dart';
import 'vnc_connection_config.dart';
import 'vnc_viewer_page.dart';

/// VNC 连接页面。
///
/// 用户输入 VNC 服务器的 Host、Port、Password 后发起连接，
/// 连接成功后导航到 [VncViewerPage]。
class VncConnectPage extends StatefulWidget {
  const VncConnectPage({super.key});

  @override
  State<VncConnectPage> createState() => _VncConnectPageState();
}

class _VncConnectPageState extends State<VncConnectPage> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController(text: '10.100.100.143');
  final _portController = TextEditingController(text: '5901');
  final _passwordController = TextEditingController();

  bool _isConnecting = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onConnect() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    final config = VncConnectionConfig(
      host: _hostController.text.trim(),
      port: int.parse(_portController.text.trim()),
      password: _passwordController.text.isNotEmpty ? _passwordController.text : null,
    );

    final manager = VncClientManager();

    await manager.connect(config);

    if (!mounted) {
      manager.dispose();
      return;
    }

    if (manager.state == VncConnectionState.connected) {
      setState(() => _isConnecting = false);

      Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) => VncViewerPage(manager: manager),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut), child: child);
          },
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
        ),
      );
    } else {
      setState(() {
        _isConnecting = false;
        _errorMessage = manager.errorMessage ?? 'Connection failed';
      });
      manager.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('VNC Client'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 24, vertical: 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.desktop_windows_rounded, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 8),
                Text(
                  'Remote Desktop',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect to a VNC server',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 32),
                _buildHostField(),
                const SizedBox(height: 16),
                _buildPortField(),
                const SizedBox(height: 16),
                _buildPasswordField(),
                const SizedBox(height: 8),
                if (_errorMessage != null) _buildErrorBanner(),
                const SizedBox(height: 24),
                _buildConnectButton(),
                const SizedBox(height: 16),
                _buildHintText(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHostField() {
    return TextFormField(
      controller: _hostController,
      decoration: const InputDecoration(
        labelText: 'Host',
        hintText: '192.168.1.100',
        prefixIcon: Icon(Icons.dns_outlined),
        border: OutlineInputBorder(),
      ),
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.next,
      enabled: !_isConnecting,
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Please enter server host';
        }
        return null;
      },
    );
  }

  Widget _buildPortField() {
    return TextFormField(
      controller: _portController,
      decoration: const InputDecoration(
        labelText: 'Port',
        hintText: '5900',
        prefixIcon: Icon(Icons.numbers),
        border: OutlineInputBorder(),
      ),
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      enabled: !_isConnecting,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Please enter port';
        }
        final port = int.tryParse(value.trim());
        if (port == null || port < 1 || port > 65535) {
          return 'Port must be between 1 and 65535';
        }
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      decoration: InputDecoration(
        labelText: 'Password (required)',
        prefixIcon: const Icon(Icons.lock_outline),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
          onPressed: () {
            setState(() => _obscurePassword = !_obscurePassword);
          },
        ),
      ),
      obscureText: _obscurePassword,
      textInputAction: TextInputAction.done,
      enabled: !_isConnecting,
      onFieldSubmitted: (_) => _onConnect(),
    );
  }

  Widget _buildErrorBanner() {
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 8),
      child: Container(
        padding: const EdgeInsetsDirectional.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadiusDirectional.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectButton() {
    return FilledButton.icon(
      onPressed: _isConnecting ? null : _onConnect,
      icon:
          _isConnecting
              ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
              )
              : const Icon(Icons.play_arrow_rounded),
      label: Text(_isConnecting ? 'Connecting...' : 'Connect'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildHintText(ThemeData theme) {
    return Text(
      'For local testing:\n'
      '  Android Emulator → use 10.0.2.2\n'
      '  iOS Simulator / Real Device → use LAN IP',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
    );
  }
}
