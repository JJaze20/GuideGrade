import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/activity_model.dart';

/// Persists the diagnostic batches/results registry to app-private device
/// storage (SharedPreferences), so it survives app restarts and version
/// upgrades — only a full uninstall clears it.
class LocalStorageService {
  static const _activitiesKey = 'recent_activities';

  Future<List<ActivityModel>> loadActivities() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activitiesKey);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.map((e) => ActivityModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveActivities(List<ActivityModel> activities) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activitiesKey, jsonEncode(activities.map((a) => a.toJson()).toList()));
  }
}
