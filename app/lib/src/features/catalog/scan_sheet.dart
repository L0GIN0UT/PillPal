import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import '../common/sheet_scaffold.dart';
import '../common/stacked_buttons.dart';
import '../common/status_message.dart';
import 'catalog_fill.dart';
import 'manual_gtin_entry.dart';
import 'scan_flow.dart';
import 'scan_viewfinder.dart';
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
  return showPillPalSheet<GtinEntered>(context, (context) => const ScanSheet());
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
    // While the person types, a code that drifts into view is not theirs.
    if (_done || _typing) {
      return;
    }
    final gtin14 = gtinOfScan(code);
    if (gtin14 == null) {
      unawaited(_adapter.pause());
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
    if (_done) {
      return;
    }
    _done = true;
    Navigator.of(context).pop(result);
  }

  bool get _cameraLost =>
      _notice == _Notice.permission || _notice == _Notice.unavailable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SheetScaffold(
      children: [
        _Header(
          title: _typing ? l10n.scanManualTitle : l10n.scanSheetTitle,
        ),
        const Gap.v(PillPalSpacing.md),
        if (_typing) ..._manual(l10n) else ..._camera(l10n),
      ],
    );
  }

  List<Widget> _camera(AppLocalizations l10n) {
    return [
      ScanViewfinder(
        preview: _adapter.buildPreview(context),
        torch: _adapter.torch,
        onTorch: () => unawaited(_adapter.toggleTorch()),
      ),
      const Gap.v(PillPalSpacing.md),
      StatusMessage(
        key: const Key('scan-privacy-note'),
        icon: Icons.info_outline,
        text: l10n.scanPrivacyNote,
      ),
      const Gap.v(PillPalSpacing.sm),
      StackedButtons(
        children: [
          OutlinedButton.icon(
            key: const Key('scan-manual'),
            onPressed: () {
              unawaited(_adapter.pause());
              setState(() => _typing = true);
            },
            icon: const Icon(Icons.keyboard_outlined),
            label: Text(l10n.scanManualAction, textAlign: TextAlign.center),
          ),
        ],
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
        onCamera: _cameraLost
            ? null
            : () {
                unawaited(_adapter.resume());
                setState(() {
                  _typing = false;
                  _notice = null;
                });
              },
      ),
    ];
  }
}

/// The title of the sheet and the way to close it (B2-ScanCamera).
class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        PillPalIconButton(
          key: const Key('scan-close'),
          icon: Icons.close,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}
