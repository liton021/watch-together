import 'dart:math';

import 'package:flutter/material.dart';

import 'room_service.dart';
import 'viewer_screen.dart';

class WatchEntryScreen extends StatefulWidget {
  const WatchEntryScreen({super.key});

  @override
  State<WatchEntryScreen> createState() => _WatchEntryScreenState();
}

class _WatchEntryScreenState extends State<WatchEntryScreen> {
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  final TextEditingController _codeController = TextEditingController();

  bool _busy = false;
  String? _error;

  String _generateCode() {
    final random = Random.secure();
    return List<int>.generate(
      6,
      (_) => random.nextInt(_alphabet.length),
    ).map((index) => _alphabet[index]).join();
  }

  String _userId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _createRoom() async {
    setState(() => _busy = true);
    final code = _generateCode();
    await RoomService.instance.join(code, asHost: true, userId: _userId());
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop<String>(code);
  }

  Future<void> _joinRoom() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length < 4) {
      setState(() => _error = 'Enter the room code first.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    await RoomService.instance.join(code, asHost: false, userId: _userId());
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ViewerScreen(code: code)));
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watch Together')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.groups_rounded,
                  size: 56,
                  color: Colors.deepPurpleAccent,
                ),
                const SizedBox(height: 16),
                Text(
                  'Watch together',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Create a room and share the code, or enter the code your friend gave you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _busy ? null : _createRoom,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create room (host)'),
                ),
                const SizedBox(height: 24),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'or join',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    letterSpacing: 6,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'CODE',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _joinRoom,
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('Join room'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 20),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
