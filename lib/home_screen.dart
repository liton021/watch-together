import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'watch_together/room_screen.dart';
import 'watch_together/room_service.dart';
import 'watch_together/user_store.dart';

const Color _background = Color(0xFF0B0E14);
const Color _panel = Color(0xFF12161F);
const Color _line = Color(0xFF252C3B);
const Color _accent = Color(0xFF8B9DFF);

const List<String> _adjectives = <String>[
  'Brave',
  'Calm',
  'Clever',
  'Cool',
  'Happy',
  'Kind',
  'Lucky',
  'Quiet',
  'Swift',
  'Wise',
  'Bright',
  'Gentle',
];
const List<String> _animals = <String>[
  'Panda',
  'Tiger',
  'Falcon',
  'Koala',
  'Otter',
  'Fox',
  'Wolf',
  'Eagle',
  'Dolphin',
  'Lynx',
  'Rabbit',
  'Whale',
];

String generateRoomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List<int>.generate(
    6,
    (_) => random.nextInt(alphabet.length),
  ).map((index) => alphabet[index]).join();
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _joinController = TextEditingController();

  List<SavedRoom> _rooms = <SavedRoom>[];
  bool _ready = false;
  bool _busy = false;

  String _randomName() {
    final random = Random.secure();
    return '${_adjectives[random.nextInt(_adjectives.length)]} '
        '${_animals[random.nextInt(_animals.length)]} '
        '${100 + random.nextInt(900)}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var name = _randomName();
    try {
      final saved = await UserStore.getName();
      if (saved != null && saved.trim().isNotEmpty) {
        name = saved;
      } else {
        await UserStore.setName(name);
      }
    } catch (_) {
      // Storage may be unavailable (e.g. limited web preview) — keep the
      // generated name for this session.
    }

    List<SavedRoom> rooms = <SavedRoom>[];
    try {
      rooms = await UserStore.getRooms();
    } catch (_) {
      // Previous rooms are optional; the rest of the app still works.
    }

    if (!mounted) return;
    setState(() {
      _nameController.text = name;
      _rooms = rooms;
      _ready = true;
    });
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showMessage('Please enter a name.');
      return;
    }
    try {
      await UserStore.setName(name);
    } catch (_) {}
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    _showMessage('Name saved.');
  }

  Future<void> _enterRoom(String code, {required bool asHost}) async {
    setState(() => _busy = true);
    await RoomService.instance.join(
      code,
      asHost: asHost,
      userId: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    try {
      await UserStore.addRoom(
        SavedRoom(
          code,
          asHost ? 'host' : 'viewer',
          DateTime.now().toIso8601String(),
        ),
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoomScreen(code: code, isHost: asHost),
      ),
    );
  }

  Future<void> _createRoom() async {
    final code = generateRoomCode();
    await _enterRoom(code, asHost: true);
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: code));
    _showMessage('Room $code created — code copied.');
  }

  Future<void> _joinRoom() async {
    final code = _joinController.text.trim().toUpperCase();
    if (code.length < 4) {
      _showMessage('Enter a valid room code first.');
      return;
    }
    await _enterRoom(code, asHost: false);
  }

  Future<void> _rejoin(SavedRoom room) async {
    await _enterRoom(room.code, asHost: room.role == 'host');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _joinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: _ready
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.movie_rounded, size: 48, color: _accent),
                    const SizedBox(height: 12),
                    Text(
                      'Watch Together',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Your room, your people, your movie.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 28),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Your name',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _nameController,
                                  onSubmitted: (_) => _saveName(),
                                  decoration: const InputDecoration(
                                    hintText: 'Type your name',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _saveName,
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy ? null : _createRoom,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Create room'),
                    ),
                    const SizedBox(height: 12),
                    _sectionCard(
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _joinController,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                hintText: 'Room code',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _joinRoom,
                            icon: const Icon(Icons.login_rounded),
                            label: const Text('Join group'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        const Icon(
                          Icons.history_rounded,
                          size: 18,
                          color: Colors.white54,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Previous rooms',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_rooms.isEmpty)
                      _sectionCard(
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'No previous rooms yet. Create or join one to see it here.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      ..._rooms.map(
                        (room) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _sectionCard(
                            child: ListTile(
                              onTap: _busy ? null : () => _rejoin(room),
                              leading: CircleAvatar(
                                backgroundColor: _accent.withValues(
                                  alpha: 0.18,
                                ),
                                child: Text(
                                  room.code.substring(0, 1),
                                  style: const TextStyle(
                                    color: _accent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                room.code,
                                style: const TextStyle(
                                  letterSpacing: 3,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                '${room.role == 'host' ? 'Created' : 'Joined'} · '
                                '${room.at.length >= 10 ? room.at.substring(0, 10) : room.at}',
                              ),
                              trailing: const Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: 16,
                                color: Colors.white38,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_busy) ...[
                      const SizedBox(height: 20),
                      const Center(child: CircularProgressIndicator()),
                    ],
                  ],
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: child,
    );
  }
}
