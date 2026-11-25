import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Только локальные предположения человека. Не часть Player или протокола.
class SuspicionNote {
  final String text;
  final String mark;
  const SuspicionNote({this.text = '', this.mark = ''});

  factory SuspicionNote.fromJson(Map data) => SuspicionNote(
        text: data['text'] is String
            ? (data['text'] as String).substring(
                0, (data['text'] as String).length.clamp(0, 500))
            : '',
        mark: const ['', 'suspect', 'trust'].contains(data['mark'])
            ? data['mark'] as String
            : '',
      );
  Map<String, String> toJson() => {'text': text, 'mark': mark};
}

class SuspicionStore {
  final String scope;
  const SuspicionStore(this.scope);
  String get _key => 'private_notes_v1:$scope';

  Future<Map<String, SuspicionNote>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonDecode(prefs.getString(_key) ?? '{}');
      if (data is! Map) return {};
      return {
        for (final entry in data.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: SuspicionNote.fromJson(entry.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  /// false — запись недоступна; интерфейс не должен обещать сохранение.
  Future<bool> save(Map<String, SuspicionNote> notes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_key,
          jsonEncode(notes.map((id, note) => MapEntry(id, note.toJson()))));
    } catch (_) {
      return false;
    }
  }
}
