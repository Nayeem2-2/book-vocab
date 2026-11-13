import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/book_models.dart';
import 'dictionary_service.dart';

class OcrService {
  Future<List<WordEntry>> extractWords(String imagePath, DictionaryService dictionary) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(imagePath));
      final matches = RegExp(r"[A-Za-z]+(?:['’-][A-Za-z]+)*").allMatches(result.text);
      final words = <String, String>{};
      for (final match in matches) {
        final value = match.group(0)!;
        final key = value.toLowerCase();
        words.putIfAbsent(key, () => value);
      }
      final entries = words.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return entries.map((word) => WordEntry(word: word, meanings: dictionary.meaningsFor(word))).toList();
    } finally {
      await recognizer.close();
    }
  }
}
