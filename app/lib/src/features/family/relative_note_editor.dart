import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/repositories/validation.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../auth/auth_fields.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/stacked_buttons.dart';
import 'family_providers.dart';
import 'relatives_errors.dart';

/// The private note about a relative (docs/adr/0020 §4): «Заметка — видна
/// только вам». Saved online only (`PUT`, `DELETE`): offline the request
/// fails, the field keeps what was typed and nothing changes on the device.
/// The note is never logged, put in a route or sent anywhere else.
class RelativeNoteEditor extends ConsumerStatefulWidget {
  /// Creates the editor of the note about [profileId], now [note].
  const RelativeNoteEditor({
    required this.profileId,
    required this.note,
    super.key,
  });

  /// The subject: the relative's self profile or a managed profile.
  final String profileId;

  /// The stored note, or null.
  final String? note;

  @override
  ConsumerState<RelativeNoteEditor> createState() => _RelativeNoteEditorState();
}

class _RelativeNoteEditorState extends ConsumerState<RelativeNoteEditor> {
  late final TextEditingController _text =
      TextEditingController(text: widget.note ?? '');
  bool _invalid = false;
  bool _busy = false;
  String? _errorCode;
  String? _done;

  @override
  void didUpdateWidget(RelativeNoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh brought another note: show it unless the user is typing.
    if (widget.note != oldWidget.note &&
        _text.text.trim() == (oldWidget.note ?? '')) {
      _text.text = widget.note ?? '';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _errorCode;
    final done = _done;
    final unchanged = _text.text.trim() == (widget.note ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('relative-note-field'),
          controller: _text,
          enabled: !_busy,
          maxLines: 1,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: const [
            CodePointLimitFormatter(FieldLimits.relativeNote),
          ],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          onChanged: (_) => setState(() {
            _invalid = false;
            _errorCode = null;
            _done = null;
          }),
          decoration: InputDecoration(
            labelText: l10n.relativeNoteLabel,
            helperText: l10n.relativeNoteHint,
            // The helper may wrap on narrow screens and with large text.
            helperMaxLines: 3,
            errorText: _invalid ? l10n.relativeNoteInvalid : null,
            errorMaxLines: 3,
            prefixIcon: const Icon(Icons.sticky_note_2_outlined),
          ),
        ),
        if (error != null) ...[
          const Gap.v(PillPalSpacing.md),
          PillPalBanner(
            tone: BannerTone.danger,
            liveRegion: true,
            body: _errorText(l10n, error),
            bodyKey: const Key('relative-note-error'),
          ),
        ],
        if (done != null) ...[
          const Gap.v(PillPalSpacing.md),
          PillPalBanner(
            liveRegion: true,
            body: done,
            bodyKey: const Key('relative-note-done'),
          ),
        ],
        const Gap.v(PillPalSpacing.md),
        StackedButtons(
          children: [
            OutlinedButton(
              key: const Key('relative-note-save'),
              onPressed: _busy || unchanged ? null : _save,
              child: _busy
                  ? const SizedBox.square(
                      dimension: PillPalSizes.spinner,
                      child: CircularProgressIndicator(
                        strokeWidth: PillPalSizes.spinnerStroke,
                      ),
                    )
                  : Text(l10n.relativeNoteSave),
            ),
            if (widget.note != null)
              TextButton(
                key: const Key('relative-note-clear'),
                onPressed: _busy ? null : _clear,
                child: Text(l10n.relativeNoteClear),
              ),
          ],
        ),
      ],
    );
  }

  String _errorText(AppLocalizations l10n, String code) =>
      code == ApiException.networkError
          ? l10n.relativeNoteOffline
          : relativesErrorMessage(l10n, code);

  Future<void> _save() async {
    if (_busy) {
      return;
    }
    if (!isRelativeNote(_text.text)) {
      setState(() => _invalid = true);
      return;
    }
    final note = relativeNote(_text.text, 'note');
    if (note == widget.note) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    await _run(
      () => ref.read(familyActionsProvider).saveNote(widget.profileId, note),
      l10n.relativeNoteSaved,
    );
  }

  Future<void> _clear() async {
    final l10n = AppLocalizations.of(context);
    final cleared = await _run(
      () => ref.read(familyActionsProvider).clearNote(widget.profileId),
      l10n.relativeNoteCleared,
    );
    if (cleared && mounted) {
      setState(_text.clear);
    }
  }

  /// Runs [request]; says [success] when it worked, the error otherwise.
  Future<bool> _run(Future<void> Function() request, String success) async {
    setState(() {
      _busy = true;
      _errorCode = null;
      _done = null;
    });
    String? code;
    try {
      await request();
    } on ApiException catch (error) {
      code = error.code;
    } on Exception {
      // Unexpected (a database error): the generic message.
      code = ApiException.invalidResponse;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _errorCode = code;
        _done = code == null ? success : null;
      });
    }
    return code == null;
  }
}
