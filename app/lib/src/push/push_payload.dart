import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// What a push is about (`t`, ADR 0008 §2).
enum PushKind {
  /// A dose is still unmarked after the alert threshold.
  missed('missed'),

  /// A late mark arrived: the `missed` alert is obsolete.
  resolved('resolved'),

  /// Someone accepted an invite of this account.
  linkAccepted('link_accepted'),

  /// A relative's account was restored after a deletion request.
  linkRestored('link_restored');

  const PushKind(this.wire);

  /// The value on the wire.
  final String wire;

  /// The kind named [wire], or null for anything this app does not know:
  /// an unknown kind is ignored, so a newer server can add kinds.
  static PushKind? fromWire(Object? wire) {
    for (final kind in values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    return null;
  }

  /// Whether the push is about a dose (`missed` or `resolved`), as opposed to
  /// a change of the links between accounts.
  bool get isDoseAlert => this == missed || this == resolved;
}

/// Protocol version this app understands (`v`).
const int pushPayloadVersion = 1;

/// The alert state flag of `s`: no confirmation, the phone was not synced.
const String unconfirmedFlag = 'u';

/// Mask of the id part of an alert notification id: ids stay in the app range
/// `firstAppNotificationId..maxNotificationId` (ADR 0001 §3).
const int _alertIdMask = 0x3fffffff;

const Set<String> _wireKeys = {'v', 't', 'a', 'p', 'm', 'g', 's'};

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
  r'-[0-9a-fA-F]{12}$',
);

/// The payload of a push, mirroring `backend/app/push/base.py`
/// (`PushPayload`): ids and enums only, never names, doses or times.
@immutable
class PushPayload {
  const PushPayload._({
    required this.kind,
    required this.profileId,
    this.alertId,
    this.medicationId,
    this.grantId,
    this.unconfirmed = false,
  });

  /// Parses the data of a push message; null unless it is exactly a payload
  /// of this protocol version: only the known keys, string values, UUIDs
  /// where ids are expected, and the ids the kind requires (and none it
  /// forbids). The data comes from outside the app, so everything else is
  /// ignored rather than guessed at.
  static PushPayload? tryParse(Map<Object?, Object?>? data) {
    if (data == null || !data.keys.every(_wireKeys.contains)) {
      return null;
    }
    if (!_isVersion(data['v'])) {
      return null;
    }
    final kind = PushKind.fromWire(data['t']);
    final profile = _uuid(data['p']);
    if (kind == null || profile == null) {
      return null;
    }
    final alert = _uuid(data['a']);
    final medication = _uuid(data['m']);
    final grant = _uuid(data['g']);
    final flag = data['s'];
    if (!_idsMatchKind(kind, data, alert: alert, grant: grant)) {
      return null;
    }
    if (data.containsKey('m') && medication == null) {
      return null;
    }
    if (flag != null && (flag != unconfirmedFlag || kind != PushKind.missed)) {
      return null;
    }
    return PushPayload._(
      kind: kind,
      profileId: profile,
      alertId: alert,
      medicationId: medication,
      grantId: grant,
      unconfirmed: flag == unconfirmedFlag,
    );
  }

  /// Parses the JSON form of [encode] (the payload of a local notification);
  /// null for anything else, including the payload of a dose reminder.
  static PushPayload? tryDecode(String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      return json is Map<String, Object?> ? tryParse(json) : null;
    } on FormatException {
      return null;
    }
  }

  static bool _isVersion(Object? value) =>
      value == pushPayloadVersion.toString() || value == pushPayloadVersion;

  static String? _uuid(Object? value) {
    if (value is String && _uuidPattern.hasMatch(value)) {
      return value.toLowerCase();
    }
    return null;
  }

  /// `missed` and `resolved` carry an alert id and no grant; the link kinds
  /// carry a grant id and neither alert, medication nor flag.
  static bool _idsMatchKind(
    PushKind kind,
    Map<Object?, Object?> data, {
    required String? alert,
    required String? grant,
  }) {
    if (kind.isDoseAlert) {
      return alert != null && !data.containsKey('g');
    }
    return grant != null &&
        !data.containsKey('a') &&
        !data.containsKey('m') &&
        !data.containsKey('s');
  }

  /// What the push is about.
  final PushKind kind;

  /// The profile concerned (`p`): its owner's alert, or the link's profile.
  final String profileId;

  /// The server's alert id (`a`) of a dose alert.
  final String? alertId;

  /// The medication (`m`), only sent for medications the relative may see.
  final String? medicationId;

  /// The grant (`g`) of a link push.
  final String? grantId;

  /// The alert is `unconfirmed` (`s` = `u`): the owner's phone had not synced
  /// since before the dose was due (ADR 0007 §4).
  final bool unconfirmed;

  /// The notification id of this push: in the app range (ADR 0001 §3) and
  /// derived from the alert id (the grant id for link pushes), so a `resolved`
  /// push finds the notification of its `missed` one and a repeated delivery
  /// replaces instead of piling up.
  int get notificationId {
    final key = kind.isDoseAlert ? 'alert:$alertId' : 'link:$grantId';
    return firstAppNotificationId + (fnv1a32(key) & _alertIdMask);
  }

  /// Compact JSON, the payload of the local notification (tap routing). It
  /// carries ids only, like the push it came from.
  String encode() => jsonEncode({
        'v': pushPayloadVersion,
        't': kind.wire,
        'p': profileId,
        if (alertId != null) 'a': alertId,
        if (medicationId != null) 'm': medicationId,
        if (grantId != null) 'g': grantId,
        if (unconfirmed) 's': unconfirmedFlag,
      });

  @override
  bool operator ==(Object other) =>
      other is PushPayload &&
      other.kind == kind &&
      other.profileId == profileId &&
      other.alertId == alertId &&
      other.medicationId == medicationId &&
      other.grantId == grantId &&
      other.unconfirmed == unconfirmed;

  @override
  int get hashCode => Object.hash(
        kind,
        profileId,
        alertId,
        medicationId,
        grantId,
        unconfirmed,
      );
}
