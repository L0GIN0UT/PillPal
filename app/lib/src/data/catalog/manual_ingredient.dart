import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/json.dart';
import '../repositories/local_writer.dart';
import '../repositories/validation.dart';

/// One line of the private manual composition of a medication
/// (`ManualIngredient` in spec/openapi.json, ADR 0015 §4). It stays on the
/// medication: the catalog never receives it.
@immutable
class ManualIngredient {
  /// Creates a line; [substanceId] is set when picked from the catalog.
  const ManualIngredient({
    required this.name,
    this.strengthText,
    this.substanceId,
  });

  /// Reads a line of `MedicationOut.manual_ingredients`.
  factory ManualIngredient.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return ManualIngredient(
      name: reader.string('name'),
      strengthText: reader.stringOrNull('strength_text'),
      substanceId: reader.stringOrNull('substance_id')?.toLowerCase(),
    );
  }

  /// Keys read from `ManualIngredient`.
  static const Set<String> readKeys = {
    'substance_id',
    'name',
    'strength_text',
  };

  /// Free-text name, 1..100 characters.
  final String name;

  /// Strength as typed, at most 50 characters.
  final String? strengthText;

  /// Catalog substance id; the only part used for the overlap hint.
  final String? substanceId;

  /// `ManualIngredient` JSON; every key is explicit.
  JsonMap toJson() => {
        'substance_id': substanceId,
        'name': name,
        'strength_text': strengthText,
      };

  /// This line normalised as the server stores it; throws a
  /// [DataException] (`manual_ingredients`) if the server would reject it.
  ManualIngredient validated() => ManualIngredient(
        name: requiredText(
          name,
          'manual_ingredients',
          max: FieldLimits.ingredientName,
        ),
        strengthText: optionalText(
          strengthText,
          'manual_ingredients',
          max: FieldLimits.ingredientStrength,
        ),
        substanceId: optionalUuid(substanceId, 'manual_ingredients'),
      );

  /// [lines] validated, at most [FieldLimits.manualIngredients] of them.
  static List<ManualIngredient> validatedList(List<ManualIngredient> lines) {
    if (lines.length > FieldLimits.manualIngredients) {
      throw const DataException(
        DataException.validationError,
        field: 'manual_ingredients',
      );
    }
    return lines.map((line) => line.validated()).toList();
  }

  /// The stored JSON text of [lines]; null for none.
  static String? encode(List<ManualIngredient> lines) {
    if (lines.isEmpty) {
      return null;
    }
    return jsonEncode(lines.map((line) => line.toJson()).toList());
  }

  /// The lines of a stored JSON text; empty for null.
  static List<ManualIngredient> decode(String? text) {
    if (text == null) {
      return const [];
    }
    try {
      final Object? parsed = jsonDecode(text);
      if (parsed is! List<Object?>) {
        throw const FormatException('Expected a list of ingredients');
      }
      return parseList(parsed);
    } on FormatException {
      throw const DataException(
        DataException.corruptData,
        field: 'manual_ingredients',
      );
    }
  }

  /// The lines of a decoded JSON list.
  static List<ManualIngredient> parseList(List<Object?> items) {
    return items
        .map((item) => ManualIngredient.fromJson(asJsonMap(item, 'item')))
        .toList();
  }

  @override
  bool operator ==(Object other) =>
      other is ManualIngredient &&
      other.name == name &&
      other.strengthText == strengthText &&
      other.substanceId == substanceId;

  @override
  int get hashCode => Object.hash(name, strengthText, substanceId);
}
