import 'package:flutter/material.dart';

import 'vnc/vnc_connect_page.dart';

void main() {
  runApp(const VncClientApp());
}

/// VNC Client Demo 应用入口。
class VncClientApp extends StatelessWidget {
  const VncClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VNC Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const VncConnectPage(),
    );
  }
}
