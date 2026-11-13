import 'package:flutter_test/flutter_test.dart';

import '../lib/app.dart';
import '../lib/services/book_store.dart';

void main() {
  testWidgets('Vocabulary app opens the books screen',
      (WidgetTester tester) async {
    final store = BookStore();

    await tester.pumpWidget(
      VocabularyApp(store: store),
    );

    expect(find.text('My Books'), findsOneWidget);
  });
}