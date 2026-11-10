import 'package:flutter/material.dart';
import 'package:nas_sync/nas_sync.dart';

import '../sync/inkpad_sync.dart';

/// The toolbar button: shows sync status; opens [SyncPage].
class SyncButton extends StatelessWidget {
  final InkpadSync sync;

  const SyncButton({super.key, required this.sync});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final (icon, tip) = switch (sync.status) {
          SyncStatus.off => (Icons.cloud_outlined, 'Set up sync'),
          SyncStatus.idle => (Icons.cloud_done_outlined, 'Synced'),
          SyncStatus.syncing => (Icons.cloud_sync_outlined, 'Syncing…'),
          SyncStatus.offline => (Icons.cloud_off_outlined, 'Offline: will sync when the server is reachable'),
          SyncStatus.error => (Icons.sync_problem_outlined, sync.message ?? 'Sync problem'),
        };
        return IconButton(
          tooltip: tip,
          icon: Icon(icon, color: sync.status == SyncStatus.error ? Theme.of(context).colorScheme.error : null),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SyncPage(sync: sync))),
        );
      },
    );
  }
}

/// Sign in to the NAS, or see sync status and sign out.
class SyncPage extends StatefulWidget {
  final InkpadSync sync;

  const SyncPage({super.key, required this.sync});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final _url = TextEditingController(text: widget.sync.url ?? '');
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  InkpadSync get sync => widget.sync;

  @override
  void dispose() {
    _url.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await sync.signIn(_url.text, _email.text, _password.text);
      _password.clear();
    } on PbException catch (e) {
      _error = e.status == 400 ? 'Wrong email or password.' : e.message;
    } on FormatException {
      _error = 'That server address doesn’t look right.';
    } catch (e) {
      _error = 'Could not reach the server. Check the address, and that Tailscale is on.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Sync')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: sync.signedIn ? _status(context) : _form(context),
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context) => [
        Text(
          'Keep your drawings in step across your devices, and backed up, '
          'through your own server. You need Tailscale on this device.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (sync.message != null) ...[
          const SizedBox(height: 12),
          Text(sync.message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _url,
          decoration: const InputDecoration(
            labelText: 'Server',
            hintText: 'https://yournas.your-tailnet.ts.net:8443',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _email,
          decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
          obscureText: true,
          onSubmitted: (_) => _busy ? null : _signIn(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _signIn,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Sign in'),
        ),
      ];

  List<Widget> _status(BuildContext context) {
    final last = sync.lastSynced;
    final when = last == null ? 'Not yet' : TimeOfDay.fromDateTime(last).format(context);
    final state = switch (sync.status) {
      SyncStatus.syncing => 'Syncing…',
      SyncStatus.offline => 'Offline. Drawings are saved here and will sync when the server is reachable.',
      SyncStatus.error => 'Problem: ${sync.message ?? 'unknown'}',
      _ => 'Up to date',
    };
    return [
      ListTile(leading: const Icon(Icons.person_outline), title: Text(sync.email ?? ''), subtitle: const Text('Signed in')),
      ListTile(leading: const Icon(Icons.dns_outlined), title: Text(sync.url ?? ''), subtitle: const Text('Server')),
      ListTile(leading: const Icon(Icons.schedule), title: Text(state), subtitle: Text('Last synced: $when')),
      if (sync.message != null && sync.status == SyncStatus.idle)
        ListTile(leading: const Icon(Icons.warning_amber_outlined), title: Text(sync.message!)),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: sync.status == SyncStatus.syncing ? null : sync.syncNow,
        icon: const Icon(Icons.sync),
        label: const Text('Sync now'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: sync.signOut,
        child: const Text('Sign out on this device'),
      ),
    ];
  }
}
