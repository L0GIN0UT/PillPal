import 'package:flutter/foundation.dart';

import '../db/database.dart';
import '../repositories/local_writer.dart';
import '../repositories/validation.dart';

/// The catalog references of a medication and the owner's consent to count
/// the link (ADR 0015 §4). Plain optional data: free text stays
/// authoritative.
@immutable
class CatalogLink {
  /// Creates a link. [consentVersion] belongs to the one write in which the
  /// user ticked the box (see `MedicationsRepository`); it is never read
  /// back from a row.
  const CatalogLink({
    this.productId,
    this.packageId,
    this.compositionId,
    this.gtin,
    this.shared = false,
    this.consentVersion,
  });

  /// No references.
  const CatalogLink.none() : this();

  /// The references stored on [row]; there is no consent version in a row.
  factory CatalogLink.fromRow(MedicationRow row) => CatalogLink(
        productId: row.catalogProductId,
        packageId: row.catalogPackageId,
        compositionId: row.catalogCompositionId,
        gtin: row.gtin,
        shared: row.gtinLinkShared,
      );

  /// Catalog product id.
  final String? productId;

  /// Catalog package id.
  final String? packageId;

  /// Catalog composition id.
  final String? compositionId;

  /// GTIN-14.
  final String? gtin;

  /// The owner's consent to count this (GTIN, product) pair.
  final bool shared;

  /// The consent text version the user accepted when ticking the box in
  /// this write; null for every other write.
  final int? consentVersion;

  /// Whether any reference is set.
  bool get isLinked =>
      productId != null ||
      packageId != null ||
      compositionId != null ||
      gtin != null;

  /// Whether [other] is the same (GTIN, product) pair; consent belongs to
  /// the pair and does not survive a change of either half.
  bool samePair(CatalogLink other) =>
      other.gtin == gtin && other.productId == productId;

  /// This link with [compositionId] replaced.
  CatalogLink withComposition(String? compositionId) => CatalogLink(
        productId: productId,
        packageId: packageId,
        compositionId: compositionId,
        gtin: gtin,
        shared: shared,
        consentVersion: consentVersion,
      );

  /// This link with ids lowercased and the format checked; throws a
  /// [DataException] naming the field if the server would reject it.
  CatalogLink validated() {
    final version = consentVersion;
    if (version != null &&
        (!shared || version < 1 || version > FieldLimits.consentVersionMax)) {
      throw const DataException(
        DataException.validationError,
        field: 'gtin_link_consent_version',
      );
    }
    return CatalogLink(
      productId: optionalUuid(productId, 'catalog_product_id'),
      packageId: optionalUuid(packageId, 'catalog_package_id'),
      compositionId: optionalUuid(compositionId, 'catalog_composition_id'),
      gtin: optionalGtin14(gtin, 'gtin'),
      shared: shared,
      consentVersion: version,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogLink &&
      other.productId == productId &&
      other.packageId == packageId &&
      other.compositionId == compositionId &&
      other.gtin == gtin &&
      other.shared == shared &&
      other.consentVersion == consentVersion;

  @override
  int get hashCode => Object.hash(
        productId,
        packageId,
        compositionId,
        gtin,
        shared,
        consentVersion,
      );
}
