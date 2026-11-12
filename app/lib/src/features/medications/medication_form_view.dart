import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../catalog/catalog_fill.dart';
import '../catalog/catalog_form_controller.dart';
import '../catalog/catalog_providers.dart';
import '../catalog/manual_ingredients_editor.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import '../family/profile_context.dart';
import 'medication_catalog_block.dart';
import 'medication_form.dart';
import 'medication_providers.dart';
import 'medication_removal.dart';
import 'medication_sections.dart';
import 'medication_stock_fields.dart';
import 'medication_text_fields.dart';

/// The medication form: free text first, with the optional catalog link and
/// manual composition (Phase 4) when the build has a catalog.
class MedicationFormView extends ConsumerStatefulWidget {
  /// Creates the form. [row] is the stored medication (null for a new one).
  const MedicationFormView({
    required this.medicationId,
    required this.initial,
    this.row,
    this.profileId,
    this.access,
    this.autoScan = false,
    super.key,
  });

  /// The medication being edited; null for a new one.
  final String? medicationId;

  /// The stored medication, for the catalog references and composition.
  final MedicationRow? row;

  /// The profile a new medication goes to (null: the user's own), or the
  /// profile of the medication being edited.
  final String? profileId;

  /// What the account may do on the profile the medication belongs to; null
  /// only for a new medication of the own profile before its first pull.
  final ProfileAccess? access;

  /// Whether the catalog section opens the scanner once the form is shown
  /// (a new medication started with the scan button).
  final bool autoScan;

  /// The form values to start from.
  final MedicationFormInput initial;

  @override
  ConsumerState<MedicationFormView> createState() => _MedicationFormState();
}

class _MedicationFormState extends ConsumerState<MedicationFormView> {
  late final TextEditingController _name;
  late final TextEditingController _form;
  late final TextEditingController _strength;
  late final TextEditingController _notes;
  late final TextEditingController _zone;
  late final TextEditingController _stockCount;
  late final TextEditingController _lowStockDays;
  late final CatalogFormController _catalog;
  final FocusNode _nameFocus = FocusNode();
  late String _stockUnit;
  late MedicationPrivacy _privacy;
  late bool _fixedZone;
  late bool _trackStock;
  Map<MedicationField, String> _errors = const {};
  bool _saving = false;

  bool get _isNew => widget.medicationId == null;

  bool get _canDelete => widget.access?.canDelete ?? false;

  bool get _canChangePrivacy =>
      widget.access?.canChangePrivacy ?? widget.profileId == null;

  void _clearErrors() {
    if (_errors.isNotEmpty) {
      setState(() => _errors = const {});
    }
  }

  /// The catalog UI exists only in a build with a catalog, and never for a
  /// redacted medication (nothing of it may be shown).
  bool get _catalogVisible =>
      ref.read(catalogEnabledProvider) && !(widget.row?.redacted ?? false);

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
    _catalog = CatalogFormController.fromRow(widget.row);
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
    _catalog.dispose();
    _nameFocus.dispose();
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
        catalogLink: _catalogVisible ? _catalog.draftLink : null,
        manualIngredients: _catalogVisible ? _catalog.draftIngredients : null,
      );

  TextEditingController _controllerOf(CatalogTextField field) {
    return switch (field) {
      CatalogTextField.name => _name,
      CatalogTextField.form => _form,
      CatalogTextField.strength => _strength,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = widget.medicationId;
    return Scaffold(
      appBar: _appBar(l10n, id),
      body: SafeArea(
        child: ListView(
          padding: PillPalSpacing.form,
          children: [
            if (_catalogVisible)
              MedicationCatalogBlock(
                controller: _catalog,
                profileId: widget.profileId,
                medicationId: widget.medicationId,
                fullAccess: _canChangePrivacy,
                autoScan: widget.autoScan,
                nameFocus: _nameFocus,
                readText: (field) => _controllerOf(field).text,
                writeText: (field, value) {
                  _controllerOf(field).text = value;
                  _clearErrors();
                },
              ),
            ..._fields(l10n),
            _stockSection(l10n),
            if (_catalogVisible) ...[
              const Gap.v(PillPalSpacing.lg),
              ManualIngredientsEditor(
                initial: _catalog.ingredients,
                onChanged: _catalog.setIngredients,
              ),
            ],
            if (id != null) ..._savedSections(id),
            const Gap.v(PillPalSpacing.xxl),
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

  /// Text, privacy and time zone fields.
  List<Widget> _fields(AppLocalizations l10n) {
    return [
      MedicationTextFields(
        name: _name,
        nameFocus: _nameFocus,
        strength: _strength,
        form: _form,
        notes: _notes,
        errorOf: (field) => _errorText(l10n, field),
        onEdited: _clearErrors,
      ),
      const Gap.v(PillPalSpacing.sm),
      PrivacySection(
        value: _privacy,
        canChange: _canChangePrivacy,
        onChanged: (value) => setState(() => _privacy = value),
      ),
      const Gap.v(PillPalSpacing.lg),
      MedicationZoneFields(
        fixed: _fixedZone,
        zone: _zone,
        error: _errorText(l10n, MedicationField.zone),
        onFixed: (value) => setState(() => _fixedZone = value),
        onEdited: _clearErrors,
      ),
    ];
  }

  PreferredSizeWidget _appBar(AppLocalizations l10n, String? id) {
    return AppBar(
      title: Text(_isNew ? l10n.newMedicationTitle : l10n.editMedicationTitle),
      actions: [
        if (id != null && _canDelete)
          PillPalIconButton(
            key: const Key('med-delete'),
            tooltip: l10n.deleteMedication,
            icon: Icons.delete_outline,
            onPressed: () => removeMedication(context, ref, id),
          ),
      ],
    );
  }

  /// What exists only once the medication is saved.
  List<Widget> _savedSections(String id) {
    return [
      const Gap.v(PillPalSpacing.lg),
      SchedulesSection(medicationId: id),
    ];
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

  /// Keeps the card of the product just linked, so it works offline. The
  /// medication is already saved, so a cache failure is not an error.
  Future<void> _rememberCard() async {
    final card = _catalog.card;
    if (card != null && _catalogVisible) {
      await rememberCardBestEffort(
        ref.read(catalogCacheRepositoryProvider),
        card,
      );
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
        final created = await service.create(
          input.toDraft(),
          profileId: widget.profileId,
        );
        await _rememberCard();
        if (mounted) {
          context.pushReplacement(AppRoutes.newSchedule(created));
        }
      } else {
        await service.update(id, input.toDraft());
        await _rememberCard();
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
        _showError(error);
      }
    } on Object {
      // Anything else (storage): reported; the form stays for a retry.
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context);
      }
    }
  }

  void _showError(DataException error) {
    final l10n = AppLocalizations.of(context);
    final String message;
    if (error.code == DataException.parentNotFound) {
      message = l10n.profileNotReady;
    } else if (error.field == 'gtin_link_shared') {
      // The opt-in could not be recorded (offline, or switched off by the
      // server): the box is cleared and the person can save without it.
      _catalog.setTicked(value: false);
      message = l10n.catalogConsentUnavailable;
    } else {
      message = l10n.errorGeneric;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
