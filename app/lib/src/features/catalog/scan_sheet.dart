import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/status_message.dart';
import 'catalog_fill.dart';
import 'manual_gtin_entry.dart';
import 'scan_flow.dart';
import 'scanner_adapter.dart';

/// What the scan sheet hands back: a valid GTIN-14 and where it came from.
/// Nothing else of a scanned code (serial, batch, expiry) leaves the sheet.
class GtinEntered {
  /// Creates the result.
  const GtinEntered(this.gtin14, this.source);

  /// The number, 14 digits.
  final String gtin14;

  /// [GtinSource.scanned] or [GtinSource.typed].
  final GtinSource source;

  @override
  // The number is left out: it may identify a private medicine.
  String toString() => 'GtinEntered(${source.name})';
}

/// Opens the scan sheet; null when the person closed it.
Future<GtinEntered?> showScanSheet(BuildContext context) {
  return showModalBottomSheet<GtinEntered>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => const ScanSheet(),
  );
}

enum _Notice { permission, unavailable, unsupported }

/// The camera with a way out to manual entry. A code is read once; an
/// unreadable code, a refused permission or a missing camera switch the
/// sheet to typing the number. No image is taken or kept.
class ScanSheet extends ConsumerStatefulWidget {
  /// Creates the sheet.
  const ScanSheet({super.key});

  @override
  ConsumerState<ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends ConsumerState<ScanSheet> {
  static const double _previewHeight = 260;

  late final ScannerAdapter _adapter;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _typing = false;
  bool _done = false;
  _Notice? _notice;

  @override
  void initState() {
    super.initState();
    _adapter = ref.read(scannerAdapterFactoryProvider)();
    _subscriptions
      ..add(_adapter.barcodes.listen(_onCode))
      ..add(_adapter.failures.listen(_onFailure));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_adapter.dispose());
    super.dispose();
  }

  void _onCode(ScanBarcode code) {
    if (_done) {
      return;
    }
    final gtin14 = gtinOfScan(code);
    if (gtin14 == null) {
      setState(() {
        _typing = true;
        _notice = _Notice.unsupported;
      });
      return;
    }
    _finish(GtinEntered(gtin14, GtinSource.scanned));
  }

  void _onFailure(ScannerFailure failure) {
    if (_done) {
      return;
    }
    setState(() {
      _typing = true;
      _notice = failure == ScannerFailure.permissionDenied
          ? _Notice.permission
          : _Notice.unavailable;
    });
  }

  void _finish(GtinEntered result) {
    _done = true;
    Navigator.of(context).pop(result);
  }

  bool get _cameraLost =>
      _notice == _Notice.permission || _notice == _Notice.unavailable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final insets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SingleChildScrollView(
        padding: PillPalSpacing.sheet,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.scanSheetTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Gap.v(PillPalSpacing.md),
            if (_typing) ..._manual(l10n) else ..._camera(l10n),
          ],
        ),
      ),
    );
  }

  List<Widget> _camera(AppLocalizations l10n) {
    return [
      SizedBox(
        height: _previewHeight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PillPalSpacing.md),
          child: _adapter.buildPreview(context),
        ),
      ),
      const Gap.v(PillPalSpacing.md),
      StatusMessage(
        key: const Key('scan-privacy-note'),
        icon: Icons.info_outline,
        text: l10n.scanPrivacyNote,
      ),
      const Gap.v(PillPalSpacing.sm),
      TextButton(
        key: const Key('scan-manual'),
        onPressed: () => setState(() => _typing = true),
        child: Text(l10n.scanManualAction),
      ),
    ];
  }

  List<Widget> _manual(AppLocalizations l10n) {
    final notice = _notice;
    return [
      if (notice != null) ...[
        StatusMessage(
          key: Key('scan-notice-${notice.name}'),
          icon: Icons.edit_outlined,
          text: switch (notice) {
            _Notice.permission => l10n.scanNoticePermission,
            _Notice.unavailable => l10n.scanNoticeUnavailable,
            _Notice.unsupported => l10n.scanNoticeUnsupported,
          },
        ),
        const Gap.v(PillPalSpacing.sm),
      ],
      ManualGtinEntry(
        onGtin: (gtin14) => _finish(GtinEntered(gtin14, GtinSource.typed)),
      ),
      if (!_cameraLost) ...[
        const Gap.v(PillPalSpacing.sm),
        TextButton(
          key: const Key('scan-use-camera'),
          onPressed: () => setState(() {
            _typing = false;
            _notice = null;
          }),
          child: Text(l10n.scanUseCamera),
        ),
      ],
    ];
  }
}
