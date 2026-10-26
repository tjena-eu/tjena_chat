import 'package:flutter/material.dart';

class WarningCard extends StatelessWidget {
  final String title;
  final String text;
  final IconData icon;
  const WarningCard({required this.title, required this.text, this.icon = Icons.warning_amber_rounded, super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      color: c.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: c.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: c.onErrorContainer)),
              const SizedBox(height: 4),
              Text(text, style: TextStyle(color: c.onErrorContainer)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class ErrorText extends StatelessWidget {
  final String text;
  const ErrorText(this.text, {super.key});
  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error));
}

enum Health { ok, warn, bad, unknown }

class StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final Health health;
  final Widget? action;
  const StatusRow(this.label, this.value, this.health, {this.action, super.key});

  @override
  Widget build(BuildContext context) {
    final color = switch (health) {
      Health.ok => Colors.green,
      Health.warn => Colors.orange,
      Health.bad => Theme.of(context).colorScheme.error,
      Health.unknown => Colors.grey,
    };
    return ListTile(
      leading: Icon(Icons.circle, color: color, size: 14),
      title: Text(label),
      subtitle: Text(value),
      trailing: action,
      dense: true,
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

String ago(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

Future<bool> confirm(BuildContext context, String title, String text, {String ok = 'Continue', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
