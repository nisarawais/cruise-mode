import 'package:flutter_test/flutter_test.dart';
import 'package:nav_study_sim/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const NavStudyApp());
    await tester.pump();
    expect(find.byType(NavStudyApp), findsOneWidget);
  });
}
