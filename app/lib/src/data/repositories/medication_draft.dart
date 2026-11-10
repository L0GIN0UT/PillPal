import '../catalog/catalog_link.dart';
import '../catalog/manual_ingredient.dart';
import '../db/database.dart';
import 'local_writer.dart';
import 'validation.dart';

/// Editable fields of a medication (TZ §2.1, free input) with the optional
/// catalog link and manual composition (ADR 0015 §4).
class MedicationDraft {
  /// Creates a draft; [tzMode] `fixed` requires [fixedTz].
  const MedicationDraft({
    required this.name,
    this.form,
    this.strengthText,
    this.notes,
    this.tzMode = 'local',
    this.fixedTz,
    this.stockCount,
    this.stockUnit,
    this.lowStockDays,
    this.stockSetAt,
    this.keepStock = false,
    this.privacy = 'shared',
    this.catalogLink,
    this.manualIngredients,
  });

  /// The editable fields of [row]; its stock baseline is kept, and so are
  /// its catalog references and consent (the consent version is not part of
  /// a row, so an ordinary edit never carries one).
  factory MedicationDraft.fromRow(MedicationRow row) => MedicationDraft(
        name: row.name ?? '',
        form: row.form,
        strengthText: row.strengthText,
        notes: row.notes,
        tzMode: row.tzMode,
        fixedTz: row.fixedTz,
        stockCount: row.stockCount,
        stockUnit: row.stockUnit,
        lowStockDays: row.lowStockDays,
        stockSetAt: stockBaselineOf(row),
        privacy: row.privacy,
        catalogLink: CatalogLink.fromRow(row),
        manualIngredients: ManualIngredient.decode(row.manualIngredients),
      );

  /// Name, 1..200 characters.
  final String name;

  /// Dosage form.
  final String? form;

  /// Strength text.
  final String? strengthText;

  /// Notes.
  final String? notes;

  /// `local` or `fixed`.
  final String tzMode;

  /// IANA zone for `fixed`.
  final String? fixedTz;

  /// Decimal stock as a string with at most 3 decimals, e.g. "12.5".
  final String? stockCount;

  /// Stock unit.
  final String? stockUnit;

  /// Low-stock threshold in days (0..365).
  final int? lowStockDays;

  /// When [stockCount] was counted (the stock baseline, TZ §2.4). Null with
  /// a [stockCount] means "counted now": the repository stamps the write
  /// time. Ignored without a [stockCount].
  final DateTime? stockSetAt;

  /// Keep the stored stock count, unit and baseline on update, whatever
  /// [stockCount], [stockUnit] and [stockSetAt] say: forms that only show
  /// the stock must not overwrite a refill made meanwhile.
  final bool keepStock;

  /// `shared`, `anonymous` or `hidden`.
  final String privacy;

  /// The catalog references. Null means "keep what is stored" (none on
  /// create), so forms that know nothing about the catalog never unlink a
  /// medication; [CatalogLink.none] unlinks. The repository decides the
  /// consent of a changed link (`MedicationsRepository`).
  final CatalogLink? catalogLink;

  /// The private manual composition, at most 10 lines. Null means "keep
  /// what is stored"; an empty list clears it.
  final List<ManualIngredient>? manualIngredients;

  /// This draft with the stored stock of [row] (read inside the write).
  MedicationDraft withStockOf(MedicationRow row) => _copy(
        stockCount: row.stockCount,
        stockUnit: row.stockCount == null ? null : row.stockUnit,
        stockSetAt: stockBaselineOf(row),
        keepStock: false,
      );

  /// This draft with a freshly counted stock of [count] (a new baseline,
  /// stamped when written).
  MedicationDraft withNewStock(String count) => _copy(
        stockCount: count,
        stockUnit: stockUnit,
        stockSetAt: null,
        keepStock: false,
      );

  /// This draft pointing at [link] (an unlinked draft: [CatalogLink.none]);
  /// the text fields are untouched.
  MedicationDraft withCatalogLink(CatalogLink link) => _copy(
        stockCount: stockCount,
        stockUnit: stockUnit,
        stockSetAt: stockSetAt,
        catalogLink: link,
      );

  /// This draft with the privacy level [value] (`shared`, `anonymous` or
  /// `hidden`); every other field is untouched.
  MedicationDraft withPrivacy(String value) => _copy(
        stockCount: stockCount,
        stockUnit: stockUnit,
        stockSetAt: stockSetAt,
        privacy: value,
      );

  MedicationDraft _copy({
    required String? stockCount,
    required String? stockUnit,
    required DateTime? stockSetAt,
    bool? keepStock,
    CatalogLink? catalogLink,
    String? privacy,
  }) {
    return MedicationDraft(
      name: name,
      form: form,
      strengthText: strengthText,
      notes: notes,
      tzMode: tzMode,
      fixedTz: fixedTz,
      stockCount: stockCount,
      stockUnit: stockUnit,
      lowStockDays: lowStockDays,
      stockSetAt: stockSetAt,
      keepStock: keepStock ?? this.keepStock,
      privacy: privacy ?? this.privacy,
      catalogLink: catalogLink ?? this.catalogLink,
      manualIngredients: manualIngredients,
    );
  }

  List<ManualIngredient>? _validatedIngredients() {
    final lines = manualIngredients;
    return lines == null ? null : ManualIngredient.validatedList(lines);
  }

  /// This draft normalised as the server stores it; throws [DataException]
  /// (`validation_error`, with the field) if the server would reject it.
  MedicationDraft validated() {
    final mode = oneOf(tzMode, 'tz_mode', const {'local', 'fixed'});
    final fixed = fixedTz;
    final zone = fixed == null ? null : timezoneName(fixed, 'fixed_tz');
    if ((mode == 'fixed') != (zone != null)) {
      throw const DataException(
        DataException.validationError,
        field: 'fixed_tz',
      );
    }
    final count = validStockCount(stockCount, 'stock_count');
    return MedicationDraft(
      name: requiredText(name, 'name', max: FieldLimits.medicationName),
      form: optionalText(form, 'form', max: FieldLimits.shortText),
      strengthText: optionalText(
        strengthText,
        'strength_text',
        max: FieldLimits.shortText,
      ),
      notes: optionalText(notes, 'notes', max: FieldLimits.notes, trim: false),
      tzMode: mode,
      fixedTz: zone,
      stockCount: count,
      stockUnit: optionalText(stockUnit, 'stock_unit', max: FieldLimits.unit),
      lowStockDays: optionalRange(
        lowStockDays,
        'low_stock_days',
        0,
        FieldLimits.lowStockDays,
      ),
      stockSetAt: count == null ? null : stockSetAt?.toUtc(),
      keepStock: keepStock,
      privacy: oneOf(
        privacy,
        'privacy',
        const {'shared', 'anonymous', 'hidden'},
      ),
      catalogLink: catalogLink?.validated(),
      manualIngredients: _validatedIngredients(),
    );
  }
}

/// The instant [row]'s stock was counted: `stock_set_at`, or for rows
/// written before it existed the row's conflict key (the last write, which
/// set the count at the latest); null when stock is not tracked.
DateTime? stockBaselineOf(MedicationRow row) {
  if (row.stockCount == null) {
    return null;
  }
  return microsToInstant(row.stockSetAt ?? row.clientUpdatedAt);
}
