import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SavedRoom {
  const SavedRoom(this.code, this.role, this.at);

  final String code;
  final String role;
  final String at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'code': code,
    'role': role,
    'at': at,
  };

  factory SavedRoom.fromJson(Map<String, dynamic> json) => SavedRoom(
    json['code']?.toString() ?? '',
    json['role']?.toString() ?? 'viewer',
    json['at']?.toString() ?? '',
  );
}

class UserStore {
  static const String _nameKey = 'user_name';
  static const String _roomsKey = 'previous_rooms';

  static Future<String?> getName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey);
  }

  static Future<void> setName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name.trim());
  }

  static Future<List<SavedRoom>> getRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_roomsKey) ?? <String>[];
    return raw
        .map(
          (item) =>
              SavedRoom.fromJson(jsonDecode(item) as Map<String, dynamic>),
        )
        .where((room) => room.code.isNotEmpty)
        .toList()
      ..sort((a, b) => b.at.compareTo(a.at));
  }

  static Future<void> addRoom(SavedRoom room) async {
    final prefs = await SharedPreferences.getInstance();
    final rooms = await getRooms();
    rooms.removeWhere((item) => item.code == room.code);
    rooms.insert(0, room);
    await prefs.setStringList(
      _roomsKey,
      rooms.take(30).map((item) => jsonEncode(item.toJson())).toList(),
    );
  }
}
