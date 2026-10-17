import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../data/repositories/validation.dart';
import '../../routing/routes.dart';
import '../auth/auth_session.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import '../common/local_time.dart';
import 'profile_context.dart';

/// Creates (no [profileId]) or edits a managed profile: someone the user
/// looks after. Name, time zone (the zone its `local` times are read in,
/// D4), the missed-dose alert (minutes, on or off), whether this device
/// reminds for it, and the invite of a co-guardian.
class ManagedProfileScreen extends ConsumerWidget {
  /// Creates the screen.
  const ManagedProfileScreen({this.profileId, super.key});

  /// The profile to edit; null creates a new one.
  final String? profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = profileId;
    if (id == null) {
      return _ManagedProfileForm(
        access: null,
        initialZone: ref.watch(deviceTimeZoneProvider),
      );
    }
    final access = ref.watch(profileAccessProvider(id));
    final value = access.valueOrNull;
    if (value == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: access.isLoading
              ? const CircularProgressIndicator()
              : Text(AppLocalizations.of(context).relativeGone),
        ),
      );
    }
    if (!value.canEditProfile) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Text(AppLocalizations.of(context).profileReadOnly),
        ),
      );
    }
    return _ManagedProfileForm(
      key: ValueKey(id),
      access: value,
      initialZone: value.profile.timezone,
    );
  }
}

class _ManagedProfileForm extends ConsumerStatefulWidget {
  const _ManagedProfileForm({
    required this.access,
    required this.initialZone,
    super.key,
  });

  final ProfileAccess? access;
  final String initialZone;

  @override
  ConsumerState<_ManagedProfileForm> createState() => _FormState();
}

class _FormState extends ConsumerState<_ManagedProfileForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.access?.profile.displayName ?? '',
  );
  late final TextEditingController _zone =
      TextEditingController(text: widget.initialZone);
  late final TextEditingController _minutes = TextEditingController(
    text:
        '${widget.access?.profile.missedAlertMinutes ?? defaultMissedAlertMinutes}',
  );
  late bool _alertsEnabled = widget.access?.profile.missedAlertsEnabled ?? true;
  bool _remind = true;
  final Set<String> _invalid = {};
  bool _saving = false;

  ProfileAccess? get _access => widget.access;

  @override
  void initState() {
    super.initState();
    final access = _access;
    if (access != null) {
      unawaited(_loadRemind(access.id));
    }
  }

  Future<void> _loadRemind(String id) async {
    final remind = await ref.read(accessRepositoryProvider).remindsOnDevice(id);
    if (mounted) {
      setState(() => _remind = remind);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _zone.dispose();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final access = _access;
    return Scaffold(
      appBar: AppBar(
        title: Text(access == null ? l10n.addWard : l10n.wardEdit),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _field(
              'ward-name',
              _name,
              l10n.wardNameLabel,
              'display_name',
              max: FieldLimits.displayName,
            ),
            _field(
              'ward-zone',
              _zone,
              l10n.zoneLabel,
              'timezone',
              hint: 'Europe/Moscow',
              max: FieldLimits.timezone,
            ),
            Text(l10n.wardZoneHint,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            SwitchListTile(
              key: const Key('ward-alerts'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.wardAlertsTitle),
              subtitle: Text(l10n.wardAlertsHint),
              value: _alertsEnabled,
              onChanged: (value) => setState(() => _alertsEnabled = value),
            ),
            if (_alertsEnabled)
              _field(
                'ward-minutes',
                _minutes,
                l10n.wardAlertMinutesLabel(
                  FieldLimits.missedAlertMinutesMin,
                  FieldLimits.missedAlertMinutesMax,
                ),
                'missed_alert_minutes',
                max: 3,
                digitsOnly: true,
              ),
            if (access != null) ..._existingOnly(context, access),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('ward-save'),
              onPressed: _saving ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _existingOnly(BuildContext context, ProfileAccess access) {
    final l10n = AppLocalizations.of(context);
    return [
      const SizedBox(height: 8),
      SwitchListTile(
        key: const Key('ward-remind'),
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.wardRemindTitle),
        subtitle: Text(l10n.wardRemindHint),
        value: _remind,
        onChanged: (value) => unawaited(_setRemind(access.id, enabled: value)),
      ),
      if (access.canManageLinks) ...[
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('ward-invite'),
          onPressed: () =>
              unawaited(context.push(AppRoutes.createInvite(access.id))),
          icon: const Icon(Icons.person_add_alt_1),
          label: Text(l10n.inviteCoGuardian),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const Key('ward-delete'),
          onPressed: _delete,
          icon: const Icon(Icons.delete_outline),
          label: Text(l10n.wardDelete),
        ),
      ],
    ];
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label,
    String wireField, {
    required int max,
    String? hint,
    bool digitsOnly = false,
  }) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key(key),
        controller: controller,
        keyboardType: digitsOnly ? TextInputType.number : null,
        inputFormatters: [
          LengthLimitingTextInputFormatter(max),
          if (digitsOnly) FilteringTextInputFormatter.digitsOnly,
        ],
        onChanged: (_) {
          if (_invalid.isNotEmpty) {
            setState(_invalid.clear);
          }
        },
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: _invalid.contains(wireField) ? l10n.invalidValue : null,
        ),
      ),
    );
  }

  Future<void> _setRemind(String id, {required bool enabled}) async {
    setState(() => _remind = enabled);
    await ref
        .read(accessRepositoryProvider)
        .setRemindOnDevice(id, enabled: enabled);
  }

  Future<void> _save() async {
    final minutes = int.tryParse(_minutes.text.trim()) ??
        (_alertsEnabled ? -1 : defaultMissedAlertMinutes);
    setState(() {
      _saving = true;
      _invalid.clear();
    });
    final repository = ref.read(profilesRepositoryProvider);
    final access = _access;
    try {
      if (access == null) {
        await repository.create(
          displayName: _name.text,
          timezone: _zone.text.trim(),
          missedAlertMinutes: minutes,
          missedAlertsEnabled: _alertsEnabled,
        );
      } else {
        await repository.update(
          access.id,
          displayName: _name.text,
          timezone: _zone.text.trim(),
          missedAlertMinutes: _alertsEnabled ? minutes : null,
          missedAlertsEnabled: _alertsEnabled,
        );
      }
      requestSync(ref);
      if (mounted) {
        context.pop();
      }
    } on DataException catch (error) {
      _showInvalid(error);
    }
  }

  void _showInvalid(DataException error) {
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      final field = error.field;
      if (field != null) {
        _invalid.add(field);
      }
    });
    if (error.field == null) {
      showErrorSnackBar(context);
    }
  }

  Future<void> _delete() async {
    final access = _access;
    if (access == null) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.wardDeleteTitle(access.profile.displayName),
      body: l10n.wardDeleteBody,
      confirmLabel: l10n.wardDelete,
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await ref.read(profilesRepositoryProvider).delete(access.id);
      requestSync(ref);
      if (mounted) {
        context.pop();
      }
    } on DataException {
      if (mounted) {
        showErrorSnackBar(context);
      }
    }
  }
}
