import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/book_models.dart';
import 'book_store.dart';

/// Presents the app's existing camera/file import choices and adds the
/// resulting images to an image book. Returns the newly created page models in
/// their original scan/import order.
Future<List<ChapterData>> addImagePagesFromSource({
  required BuildContext context,
  required BookStore store,
  required BookData book,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(sheetContext, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Pick image file'),
              onTap: () => Navigator.pop(sheetContext, 'file'),
            ),
          ],
        ),
      ),
    ),
  );

  if (choice == null) return const <ChapterData>[];

  final existingIds = book.pages.map((page) => page.stableId).toSet();

  if (choice == 'camera') {
    final result = await CunningDocumentScanner.scanDocuments();
    final paths = result?.images ?? const <String>[];
    for (final path in paths) {
      await store.addScannedPage(book, await File(path).readAsBytes());
    }
  } else {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'bmp',
        'gif',
        'tif',
        'tiff',
      ],
      allowMultiple: true,
      withData: true,
    );

    if (result != null) {
      for (final picked in result.files) {
        final bytes = picked.bytes ??
            (picked.path == null ? null : await File(picked.path!).readAsBytes());
        if (bytes != null) {
          await store.addScannedPage(book, bytes);
        }
      }
    }
  }

  return book.pages
      .where((page) => !existingIds.contains(page.stableId))
      .toList(growable: false);
}
