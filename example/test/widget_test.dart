import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_annotations_example/main.dart';

void main() {
  testWidgets('Verify PDF Annotations Example app builds', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const PdfAnnotationsExampleApp());

    // Verify that the title widget is present
    expect(find.textContaining('PDF Annotations'), findsOneWidget);
  });
}
