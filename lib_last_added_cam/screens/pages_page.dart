import 'dart:io';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/book_models.dart';
import '../services/book_store.dart';
import '../widgets/play_widgets.dart';
import 'chapter_page.dart';

class PagesPage extends StatefulWidget {
  const PagesPage({super.key, required this.store, required this.book});
  final BookStore store;
  final BookData book;
  @override
  State<PagesPage> createState() => _PagesPageState();
}

class _PagesPageState extends State<PagesPage> {
  bool busy = false;
  void _message(String value) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value))); }

  Future<void> _downloadDictionary() async {
    setState(() => busy = true);
    try {
      await widget.store.dictionary.load();
      _message('English–Bangla dictionary downloaded and cached for offline use.');
    } catch (e) {
      _message('Dictionary download failed. Check internet and retry: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addPage() async {
    final choice = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.document_scanner_outlined), title: const Text('Camera'), onTap: () => Navigator.pop(context, 'camera')), ListTile(leading: const Icon(Icons.image_outlined), title: const Text('Pick image file'), onTap: () => Navigator.pop(context, 'file'))]))));
    if (choice == null) return;
    setState(() => busy = true);
    try {
      if (choice == 'camera') {
        final result = await CunningDocumentScanner.scanDocuments();
        final paths = result?.images ?? const <String>[];
        for (final path in paths) { await widget.store.addScannedPage(widget.book, await File(path).readAsBytes()); }
        if (paths.isNotEmpty) _message('${paths.length} page(s) scanned and processed.');
      } else {
        final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'tif', 'tiff'], allowMultiple: true, withData: true);
        if (result != null) {
          for (final picked in result.files) {
            final bytes = picked.bytes ?? (picked.path == null ? null : await File(picked.path!).readAsBytes());
            if (bytes != null) await widget.store.addScannedPage(widget.book, bytes);
          }
          _message('${result.files.length} image(s) added.');
        }
      }
    } catch (e) { _message('Could not add page: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _rename(ChapterData page) async {
    final controller = TextEditingController(text: page.title);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(title: const Text('Rename page'), content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Page name')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save'))]));
    controller.dispose();
    if (name != null) { try { await widget.store.renamePage(widget.book, page, name); } catch (e) { _message('$e'); } }
  }

  Future<void> _delete(ChapterData page) async {
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('Delete page?'), content: Text('Delete ${page.title} and its saved image?'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete'))]));
    if (yes == true) await widget.store.deletePage(widget.book, page);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final pages = widget.book.pages;
        Widget pageList() {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${pages.length} pages  •  ${widget.store.totalUniqueWords(widget.book)} unique words',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      PlayButton(
                        store: widget.store,
                        title: widget.book.name,
                        chapters: pages,
                      ),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < pages.length; i++)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(10),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: SizedBox(
                        width: 58,
                        height: 72,
                        child: pages[i].imagePath != null &&
                                File(pages[i].imagePath!).existsSync()
                            ? Image.file(File(pages[i].imagePath!), fit: BoxFit.cover)
                            : const Icon(Icons.image),
                      ),
                    ),
                    title: Text(
                      pages[i].title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text('${pages[i].words.length} distinct words'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PlayButton(
                          store: widget.store,
                          title: pages[i].title,
                          chapters: [pages[i]],
                          size: 30,
                        ),
                        PopupMenuButton<String>(
                          onSelected: (value) => value == 'rename'
                              ? _rename(pages[i])
                              : _delete(pages[i]),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ],
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChapterPage(
                          store: widget.store,
                          book: widget.book,
                          chapter: pages[i],
                          pages: pages,
                          pageIndex: i,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(
              widget.book.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            actions: [
              PlayButton(
                store: widget.store,
                title: widget.book.name,
                chapters: pages,
              ),
              const SizedBox(width: 8),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: busy ? null : _addPage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Add page'),
          ),
          body: Column(
            children: [
              if (!widget.store.dictionary.isLoaded)
                MaterialBanner(
                  content: const Text('The English–Bangla dictionary is not cached yet. Internet is needed for its first download.'),
                  leading: const Icon(Icons.cloud_download_outlined),
                  actions: [TextButton(onPressed: busy ? null : _downloadDictionary, child: const Text('Download'))],
                ),
              Expanded(
                child: busy
                    ? const Center(child: CircularProgressIndicator())
                    : pages.isEmpty
                        ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.document_scanner_outlined,
                              size: 70,
                              color: Color(0xFF8AA99A),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No pages yet',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Add a page using the camera or choose an image from your device.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 18),
                            FilledButton.icon(
                              onPressed: _addPage,
                              icon: const Icon(Icons.add),
                              label: const Text('Add first page'),
                            ),
                          ],
                        ),
                      ),
                    )
                        : pageList(),
              ),
            ],
          ),
        );
      },
    );
  }

}
