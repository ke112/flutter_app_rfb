import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app_rfb/main.dart';

void main() {
  testWidgets('App renders connect page', (WidgetTester tester) async {
    await tester.pumpWidget(const VncClientApp());

    expect(find.text('Remote Desktop'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
