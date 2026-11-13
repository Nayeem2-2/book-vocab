import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/book_store.dart';
import '../widgets/play_widgets.dart';
import 'parts_page.dart';
import 'pages_page.dart';

class BooksPage extends StatelessWidget {
  const BooksPage({super.key, required this.store});
  final BookStore store;

  void _msg(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addBook(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.data_object), title: const Text('Import JSON book'), subtitle: const Text('Keep the existing Parts → Chapters structure'), onTap: () => Navigator.pop(context, 'json')),
        ListTile(leading: const Icon(Icons.document_scanner_outlined), title: const Text('Create image book'), subtitle: const Text('Add scanned or selected page images'), onTap: () => Navigator.pop(context, 'image')),
        const SizedBox(height: 12),
      ])),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'json') {
      try { await store.importBook(); } catch (e) { _msg(context, 'Could not import book: $e'); }
      return;
    }
    final controller = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Create image book'),
      content: TextField(controller: controller, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Book name', hintText: 'e.g. English Vocabulary')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Create'))],
    ));
    controller.dispose();
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    try { await store.createImageBook(name); } catch (e) { _msg(context, 'Could not create image book: $e'); }
  }

  Future<void> _exportKnown(BuildContext context) async {
    try {
      final path = await store.exportKnownWords();
      if (path != null) _msg(context, 'Known words exported');
    } catch (e) {
      _msg(context, 'Export failed: $e');
    }
  }

  Future<void> _importKnown(BuildContext context) async {
    try {
      final added = await store.importKnownWords();
      if (added != null) {
        _msg(context, 'Imported and merged • $added new known words');
      }
    } catch (e) {
      _msg(context, 'Import failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Books',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Add a book',
            onPressed: () => _addBook(context),
            icon: const Icon(Icons.add_circle_outline, size: 28),
          ),
          PopupMenuButton<String>(
            tooltip: 'Known words',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'export') _exportKnown(context);
              if (value == 'import') _importKnown(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.file_upload_outlined),
                  title: Text('Export known words'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  leading: Icon(Icons.file_download_outlined),
                  title: Text('Import known words'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addBook(context),
        icon: const Icon(Icons.add),
        label: const Text('Add book'),
      ),
      body: store.books.isEmpty
          ? _EmptyState(onAdd: () => _addBook(context))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                const Text(
                  'Your vocabulary library',
                  style: TextStyle(fontSize: 14, color: Colors.black54),
                ),
                const SizedBox(height: 14),
                for (final book in store.books)
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                      leading: Container(
                        width: 52,
                        height: 58,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F1EC),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.menu_book_rounded,
                            color: Color(0xFF356859), size: 30),
                      ),
                      title: Text(book.name,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${book.isImageBook ? '${book.pages.length} Pages' : '${book.parts.length} Parts'}  •  ${store.totalUniqueWords(book)} unique words\n${store.knownCount(book)} known',
                        ),
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PlayButton(
                            store: store,
                            title: book.name,
                            chapters: book.allChapters,
                            size: 34,
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => book.isImageBook
                                ? PagesPage(store: store, book: book)
                                : PartsPage(store: store, book: book)),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.library_books_outlined,
                  size: 76, color: Color(0xFF8AA99A)),
              const SizedBox(height: 18),
              const Text('Your library is empty',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                'Add a JSON vocabulary book or create an image book from scanned pages.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Add a book')),
            ],
          ),
        ),
      );
}

// ───────────────────────── Parts / Chapters ─────────────────────────
