import 'package:shared_preferences/shared_preferences.dart';

enum BrowseLayout { list, grid }

class BrowseViewPreference {
  const BrowseViewPreference({
    required this.layout,
    required this.listSize,
    required this.gridSize,
  });

  final BrowseLayout layout;
  final int listSize;
  final int gridSize;

  int get size => layout == BrowseLayout.list ? listSize : gridSize;
}

/// Device-local display preferences. List and Grid density are independent
/// and deliberately do not sync to Firebase.
class ViewPreferencesService {
  static Future<BrowseViewPreference> load(String screenKey) async {
    final prefs = await SharedPreferences.getInstance();
    final layoutName = prefs.getString('view_${screenKey}_layout') ?? 'list';
    final listSize = (prefs.getInt('view_${screenKey}_list_size') ?? 3).clamp(1, 5).toInt();
    final gridSize = (prefs.getInt('view_${screenKey}_grid_size') ?? 3).clamp(1, 5).toInt();
    return BrowseViewPreference(
      layout: layoutName == 'grid' ? BrowseLayout.grid : BrowseLayout.list,
      listSize: listSize,
      gridSize: gridSize,
    );
  }

  static Future<void> save(String screenKey, BrowseViewPreference preference) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'view_${screenKey}_layout',
      preference.layout == BrowseLayout.grid ? 'grid' : 'list',
    );
    await prefs.setInt('view_${screenKey}_list_size', preference.listSize.clamp(1, 5).toInt());
    await prefs.setInt('view_${screenKey}_grid_size', preference.gridSize.clamp(1, 5).toInt());
  }
}
