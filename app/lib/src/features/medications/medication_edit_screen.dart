import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/local_writer.dart';
import '../../routing/routes.dart';
import '../common/error_snack_bar.dart';
import '../common/local_time.dart';
import '../family/profile_context.dart';
import '../reminders/reminder_settings_sections.dart';
import 'medication_form.dart';
import 'medication_providers.dart';
import 'medication_removal.dart';
import 'medication_sections.dart';
import 'medication_stock_fields.dart';
import 'medication_text_fields.dart';

/// Add (no [medicationId]) or edit a medication (mockup "AddMedication";
/// scan and catalog are Phase 4, so free input is the path for now).
///
/// What the form offers follows the role on the medication's profile:
/// editors change `shared` medications only, never their privacy and never
/// delete (D3); viewers get no form at all.
class MedicationEditScreen extends ConsumerWidget {
  /// Creates the screen.
  const MedicationEditScreen({this.medicationId, this.profileId, super.key});

  /// Medication to edit; null adds a new one.
  final String? medicationId;

  /// The profile a new medication goes to; null is the user's own.
  final String? profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tz = ref.watch(deviceTimeZoneProvider);
    final id = medicationId;
    if (id == null) {
      return _newMedication(context, ref, tz);
    }
    final medication = ref.watch(medicationByIdProvider(id));
    return medication.when(
      skipLoadingOnReload: true,
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.errorGeneric)),
      ),
      data: (row) {
        if (row == null) {
          return _message(l10n.medicationNotFound);
        }
        final access = ref.watch(medicationAccessProvider(id)).valueOrNull;
        if (access != null &&
            !access.canEditMedication(
              privacy: row.privacy,
              redacted: row.redacted,
            )) {
          return _message(l10n.medicationReadOnly);
        }
        return _MedicationFormView(
          key: ValueKey(id),
          medicationId: id,
          access: access,
          initial: MedicationFormInput.fromRow(row, tz),
        );
      },
    );
  }

  Widget _newMedication(BuildContext context, WidgetRef ref, String tz) {
    final target = profileId;
    final access = target == null
        ? null
        : ref.watch(profileAccessProvider(target)).valueOrNull;
    if (target != null && access == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (access != null && !access.canEditMedications) {
      return _message(AppLocalizations.of(context).medicationReadOnly);
    }
    return _MedicationFormView(
      medicationId: null,
      profileId: target,
      access: access,
      // A new medication of someone else's profile starts `shared`: only the
      // owner and guardians may hide it (D3).
      initial: MedicationFormInput(zone: tz),
    );
  }

  Widget _message(String text) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(text)),
      );
}

class _MedicationFormView extends ConsumerStatefulWidget {
  const _MedicationFormView({
    required this.medicationId,
    required this.initial,
    this.profileId,
    this.access,
    super.key,
  });

  final String? medicationId;
  final String? profileId;

  /// The role on the profile; null for the user's own, before it is known.
  final ProfileAccess? access;
  final MedicationFormInput initial;

  @override
  ConsumerState<_MedicationFormView> createState() => _MedicationFormState();
}

class _MedicationFormState extends ConsumerState<_MedicationFormView> {
  late final TextEditingController _name;
  late final TextEditingController _form;
  late final TextEditingController _strength;
  late final TextEditingController _notes;
  late final TextEditingController _zone;
  late final TextEditingController _stockCount;
  late final TextEditingController _lowStockDays;
  late String _stockUnit;
  late MedicationPrivacy _privacy;
  late bool _fixedZone;
  late bool _trackStock;
  Map<MedicationField, String> _errors = const {};
  bool _saving = false;

  bool get _isNew => widget.medicationId == null;

  bool get _canDelete => widget.access?.canDelete ?? true;

  bool get _canChangePrivacy => widget.access?.canChangePrivacy ?? true;

  void _clearErrors() {
    if (_errors.isNotEmpty) {
      setState(() => _errors = const {});
    }
  }

  bool get _mayRemind => widget.access?.mayRemind ?? true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial.name);
    _form = TextEditingController(text: initial.form);
    _strength = TextEditingController(text: initial.strength);
    _notes = TextEditingController(text: initial.notes);
    _zone = TextEditingController(text: initial.zone);
    _stockCount = TextEditingController(text: initial.stockCount);
    _stockUnit = initial.stockUnit;
    _lowStockDays = TextEditingController(text: initial.lowStockDays);
    _privacy = initial.privacy;
    _fixedZone = initial.fixedZone;
    _trackStock = initial.trackStock;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _form,
      _strength,
      _notes,
      _zone,
      _stockCount,
      _lowStockDays,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  MedicationFormInput get _input => MedicationFormInput(
        name: _name.text,
        form: _form.text,
        strength: _strength.text,
        notes: _notes.text,
        privacy: _privacy,
        fixedZone: _fixedZone,
        zone: _zone.text,
        trackStock: _trackStock,
        stockCount: _stockCount.text,
        stockUnit: _stockUnit,
        lowStockDays: _lowStockDays.text,
        stockBaseline: widget.initial.stockBaseline,
        initialStockUnit: widget.initial.initialStockUnit,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final id = widget.medicationId;
    return Scaffold(
      appBar: AppBar(
        title:
            Text(_isNew ? l10n.newMedicationTitle : l10n.editMedicationTitle),
        actions: [
          if (id != null && _canDelete)
            IconButton(
              key: const Key('med-delete'),
              tooltip: l10n.deleteMedication,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => removeMedication(context, ref, id),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (_isNew) ...[
              const CatalogSoonSection(),
              const SizedBox(height: 24),
              Text(l10n.manualEntry, style: textTheme.titleMedium),
              const SizedBox(height: 12),
            ],
            MedicationTextFields(
              name: _name,
              strength: _strength,
              form: _form,
              notes: _notes,
              errorOf: (field) => _errorText(l10n, field),
              onEdited: _clearErrors,
            ),
            const SizedBox(height: 8),
            Text(l10n.privacyTitle, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_canChangePrivacy) ...[
              PrivacySelector(
                value: _privacy,
                onChanged: (value) => setState(() => _privacy = value),
              ),
              const SizedBox(height: 8),
              PrivacyExplanation(value: _privacy),
            ] else
              Text(
                l10n.privacyEditorNote,
                key: const Key('privacy-editor-note'),
                style: textTheme.bodyMedium,
              ),
            const SizedBox(height: 16),
            MedicationZoneFields(
              fixed: _fixedZone,
              zone: _zone,
              error: _errorText(l10n, MedicationField.zone),
              onFixed: (value) => setState(() => _fixedZone = value),
              onEdited: _clearErrors,
            ),
            _stockSection(l10n),
            if (id != null) ...[
              const SizedBox(height: 16),
              SchedulesSection(medicationId: id),
              const SizedBox(height: 16),
              if (_mayRemind) MedicationReminderSection(medicationId: id),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('med-save'),
              onPressed: _saving ? null : _save,
              child: Text(_isNew ? l10n.nextToSchedule : l10n.save),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stockSection(AppLocalizations l10n) {
    final initial = widget.initial;
    final counted = initial.stockBaseline != null;
    // A counted stock in another unit must be counted again (ADR 0004).
    final recount = counted && _stockUnit != initial.initialStockUnit;
    return MedicationStockFields(
      medicationId: widget.medicationId,
      tracking: _trackStock,
      counted: counted && !recount,
      countHint: recount ? l10n.stockRecountHint : null,
      count: _stockCount,
      unit: _stockUnit,
      lowStockDays: _lowStockDays,
      onTracking: (value) => setState(() {
        _trackStock = value;
        _stockUnit = stockUnitWhenTracking(_stockUnit);
      }),
      onUnit: (unit) => setState(() {
        if (counted && unit != _stockUnit) {
          _stockCount.clear();
        }
        _stockUnit = unit;
        _errors = const {};
      }),
      onEdited: () {
        if (_errors.isNotEmpty) {
          setState(() => _errors = const {});
        }
      },
      countError: _errorText(l10n, MedicationField.stockCount),
      unitError: _errorText(l10n, MedicationField.stockUnit),
      daysError: _errorText(l10n, MedicationField.lowStockDays),
    );
  }

  String? _errorText(AppLocalizations l10n, MedicationField field) =>
      medicationErrorText(l10n, _errors[field]);

  Future<void> _save() async {
    final input = _input;
    final errors = input.validate();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      return;
    }
    setState(() => _saving = true);
    final service = ref.read(medicationServiceProvider);
    final id = widget.medicationId;
    try {
      if (id == null) {
        final created = await service.create(
          input.toDraft(),
          profileId: widget.profileId,
        );
        if (mounted) {
          context.pushReplacement(AppRoutes.newSchedule(created));
        }
      } else {
        await service.update(id, input.toDraft());
        if (mounted) {
          context.pop();
        }
      }
    } on DataException catch (error) {
      if (!mounted) {
        return;
      }
      // Field errors come from `MedicationDraft.validated()` (server rules).
      final field = MedicationField.ofWire(error.field);
      setState(() {
        _saving = false;
        if (field != null) {
          _errors = {field: MedicationFormErrors.invalid};
        }
      });
      if (field == null) {
        _showError(error.code);
      }
    } on Object {
      // Anything else (storage): reported; the form stays for a retry.
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context);
      }
    }
  }

  void _showError(String code) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          code == DataException.parentNotFound
              ? l10n.profileNotReady
              : l10n.errorGeneric,
        ),
      ),
    );
  }
}
