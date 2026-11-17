import 'package:flutter/material.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';

/// A reusable folder-style row used by the parts and chapters screens.
class FolderTile extends StatelessWidget {
  const FolderTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.play,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? play;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          leading: Icon(icon, color: const Color(0xFFC18A35), size: 32),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(subtitle, style: const TextStyle(color: Colors.black54)),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (play != null) play!,
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: onTap,
        ),
      );
}

/// Displays the overall known-word progress for a book.
class BookProgress extends StatelessWidget {
  const BookProgress({
    super.key,
    required this.store,
    required this.book,
  });

  final BookStore store;
  final BookData book;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: store.wordStateRevision,
      builder: (context, _, __) => FutureBuilder<void>(
        future: store.ensureBookWordCache(book),
        builder: (context, snapshot) {
          final ready = store.hasBookWordCache(book);
          final total = ready ? store.totalUniqueWords(book) : 0;
          final known = ready ? store.knownCount(book) : 0;
          final progress = total == 0
              ? 0.0
              : (known / total).clamp(0.0, 1.0).toDouble();

          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Book progress',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        ready ? '$known / $total known' : 'Calculating…',
                        style: const TextStyle(
                            color: Colors.black54, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: LinearProgressIndicator(
                      value: ready ? progress : null,
                      minHeight: 8,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
