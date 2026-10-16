import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/local_writer.dart';
import '../../routing/routes.dart';
import '../common/error_snack_bar.dart';
import '../common/local_time.dart';
import '../reminders/reminder_settings_sections.dart';
import 'medication_form.dart';
import 'medication_providers.dart';
import 'medication_removal.dart';
import 'medication_sections.dart';
import 'medication_stock_fields.dart';

/// Add (no [medicationId]) or edit a medication (mockup "AddMedication";
/// scan and catalog are Phase 4, so free input is the path for now).
class MedicationEditScreen extends ConsumerWidget {
  /// Creates the screen.
  const MedicationEditScreen({this.medicationId, super.key});

  /// Medication to edit; null adds a new one.
  final String? medicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tz = ref.watch(deviceTimeZoneProvider);
    final id = medicationId;
    if (id == null) {
      return _MedicationFormView(
        medicationId: null,
        initial: MedicationFormInput(zone: tz),
      );
    }
    final medication = ref.watch(medicationByIdProvider(id));
    return medication.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.errorGeneric)),
      ),
      data: (row) => row == null
          ? Scaffold(
              appBar: AppBar(),
              body: Center(child: Text(l10n.medicationNotFound)),
            )
          : _MedicationFormView(
              key: ValueKey(id),
              medicationId: id,
              initial: MedicationFormInput.fromRow(row, tz),
            ),
    );
  }
}

class _MedicationFormView extends ConsumerStatefulWidget {
  const _MedicationFormView({
    required this.medicationId,
    required this.initial,
    super.key,
  });

  final String? medicationId;
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
          if (id != null)
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
            ..._textFields(l10n),
            const SizedBox(height: 8),
            Text(l10n.privacyTitle, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            PrivacySelector(
              value: _privacy,
              onChanged: (value) => setState(() => _privacy = value),
            ),
            const SizedBox(height: 16),
            _zoneSection(l10n),
            _stockSection(l10n),
            if (id != null) ...[
              const SizedBox(height: 16),
              SchedulesSection(medicationId: id),
              const SizedBox(height: 16),
              MedicationReminderSection(medicationId: id),
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

  /// Name, strength, form and notes.
  List<Widget> _textFields(AppLocalizations l10n) => [
        _field(_name, 'med-name', l10n.medNameLabel,
            max: MedicationLimits.name,
            error: _errorText(l10n, MedicationField.medicationName)),
        _field(_strength, 'med-strength', l10n.medStrengthLabel,
            max: MedicationLimits.shortText,
            hint: l10n.medStrengthHint,
            error: _errorText(l10n, MedicationField.strength)),
        _field(_form, 'med-form', l10n.medFormLabel,
            max: MedicationLimits.shortText,
            hint: l10n.medFormHint,
            error: _errorText(l10n, MedicationField.form)),
        _field(_notes, 'med-notes', l10n.medNotesLabel,
            max: MedicationLimits.notes,
            hint: l10n.medNotesHint,
            error: _errorText(l10n, MedicationField.notes)),
      ];

  Widget _field(
    TextEditingController controller,
    String key,
    String label, {
    required int max,
    String? hint,
    String? error,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key(key),
        controller: controller,
        keyboardType: keyboard,
        inputFormatters: [LengthLimitingTextInputFormatter(max)],
        onChanged: (_) {
          if (_errors.isNotEmpty) {
            setState(() => _errors = const {});
          }
        },
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
          errorMaxLines: 3,
        ),
      ),
    );
  }

  Widget _zoneSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('med-zone-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.fixedZoneTitle),
          subtitle: Text(l10n.fixedZoneHint),
          value: _fixedZone,
          onChanged: (value) => setState(() => _fixedZone = value),
        ),
        if (_fixedZone)
          _field(_zone, 'med-zone', l10n.zoneLabel,
              max: MedicationLimits.shortText,
              hint: 'Europe/Moscow',
              error: _errorText(l10n, MedicationField.zone)),
      ],
    );
  }

  Widget _stockSection(AppLocalizations l10n) {
    return MedicationStockFields(
      medicationId: widget.medicationId,
      tracking: _trackStock,
      counted: widget.initial.stockBaseline != null,
      count: _stockCount,
      unit: _stockUnit,
      lowStockDays: _lowStockDays,
      onTracking: (value) => setState(() {
        _trackStock = value;
        _stockUnit = stockUnitWhenTracking(_stockUnit);
      }),
      onUnit: (unit) => setState(() {
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

  String? _errorText(AppLocalizations l10n, MedicationField field) {
    switch (_errors[field]) {
      case null:
        return null;
      case MedicationFormErrors.required:
        return l10n.fieldRequired;
      case MedicationFormErrors.invalidZone:
        return l10n.invalidZone;
      case MedicationFormErrors.invalid:
        return l10n.invalidValue;
      default:
        return l10n.invalidNumber;
    }
  }

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
        final created = await service.create(input.toDraft());
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
