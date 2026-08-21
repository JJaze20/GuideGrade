import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/activity_model.dart';
import '../../models/answer_key.dart';

/// Persists the diagnostic batches/results registry and manually-entered
/// answer keys to app-private device storage (SharedPreferences), so both
/// survive app restarts, reinstalls of a new debug build, and version
/// upgrades — only a full uninstall clears it. Answer keys in particular
/// are tedious to re-enter by hand (72 taps for AT), so surviving a
/// same-device reinstall during iterative testing matters a lot in
/// practice, not just as a nice-to-have.
class LocalStorageService {
  static const _activitiesKey = 'recent_activities';
  static const _answerKeysKey = 'answer_keys';

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

  Future<Map<String, AnswerKey>> loadAnswerKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_answerKeysKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((code, json) => MapEntry(code, AnswerKey.fromJson(json as Map<String, dynamic>)));
  }

  Future<void> saveAnswerKeys(Map<String, AnswerKey> answerKeys) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_answerKeysKey, jsonEncode(answerKeys.map((code, key) => MapEntry(code, key.toJson()))));
  }
}
