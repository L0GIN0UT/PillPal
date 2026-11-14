import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/validation.dart';
import '../../routing/routes.dart';
import '../auth/auth_errors.dart';
import '../auth/auth_fields.dart';
import '../auth/auth_flow_state.dart';
import '../auth/auth_session.dart';
import '../auth/auth_widgets.dart';
import '../common/compact_rows.dart';
import '../common/list_row.dart';
import '../doses/dose_providers.dart';

/// The name the server gave every `self` profile before sign-up asked for one
/// (R10). It is not the person's name, so the app treats it as unset.
const String legacyDefaultSelfName = 'Me';

/// The person's own name stored on [self], or null when there is none yet:
/// no profile before the first pull, or the legacy default.
String? ownNameOf(ProfileRow? self) {
  final name = self?.displayName;
  return name == null || name == legacyDefaultSelfName ? null : name;
}

/// The own name as Settings shows it; the account card re-decides its narrow
/// layout when it changes.
final ownNameProvider = Provider<String?>(
  (ref) => ownNameOf(ref.watch(selfProfileProvider).valueOrNull),
);

/// «Ваше имя»: the first row of the account card, with the stored name under
/// the title («Укажите имя» while there is none). The name is the `self`
/// profile's, the one relatives see.
class OwnNameRow extends ConsumerWidget implements NarrowAware {
  /// Creates the row.
  const OwnNameRow({super.key});

  PillPalListRow _row(BuildContext context, String? name) {
    final l10n = AppLocalizations.of(context);
    return PillPalListRow(
      key: const Key('settings-own-name'),
      title: l10n.settingsOwnName,
      subtitle: name ?? l10n.settingsOwnNameUnset,
      leadingIcon: Icons.person_outline,
      onTap: () => unawaited(context.push(AppRoutes.ownName)),
    );
  }

  @override
  double fullLayoutWidth(BuildContext context) {
    final name =
        ProviderScope.containerOf(context, listen: false).read(ownNameProvider);
    return _row(context, name).fullLayoutWidth(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _row(context, ref.watch(ownNameProvider));
}

/// Change of the person's own name (Settings -> Account): one field, checked
/// like at registration (`isPersonName`), written to the `self` profile on
/// the device and sent with the next sync. Until the first pull delivered the
/// profile there is nothing to rename: the field and «Сохранить» stay off and
/// a line says why; the stored name fills the field when it arrives, unless
/// the user already typed.
class OwnNameScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const OwnNameScreen({super.key});

  @override
  ConsumerState<OwnNameScreen> createState() => _OwnNameScreenState();
}

class _OwnNameScreenState extends ConsumerState<OwnNameScreen> {
  late final TextEditingController _name =
      TextEditingController(text: ref.read(ownNameProvider) ?? '');
  bool _edited = false;
  String? _errorCode;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ownNameProvider, (_, name) {
      if (!_edited && name != null) {
        _name.text = name;
      }
    });
    final l10n = AppLocalizations.of(context);
    final ready = ref.watch(selfProfileProvider).valueOrNull != null;
    final error = _errorCode;
    return AuthScaffold(
      title: l10n.ownNameTitle,
      pinnedNotice: AuthDisabledReason(
        text: l10n.ownNameWaitSync,
        visible: !ready,
        textKey: const Key('own-name-wait'),
      ),
      actions: [
        BusyButton(
          key: const Key('own-name-save'),
          label: l10n.save,
          busy: _saving,
          enabled: ready,
          disabledReason: l10n.ownNameWaitSync,
          onPressed: _save,
        ),
      ],
      children: [
        AuthNameField(
          fieldKey: const Key('own-name-field'),
          controller: _name,
          enabled: ready && !_saving,
          errorText: error == null ? null : authErrorMessage(l10n, error),
          onChanged: (_) => setState(() {
            _edited = true;
            _errorCode = null;
          }),
          onSubmitted: _save,
        ),
      ],
    );
  }

  Future<void> _save() async {
    final self = ref.read(selfProfileProvider).valueOrNull;
    if (_saving || self == null) {
      return;
    }
    final name = _name.text.trim();
    if (!isPersonName(name)) {
      setState(() => _errorCode = AuthClientErrors.invalidName);
      return;
    }
    if (name == self.displayName) {
      context.pop();
      return;
    }
    setState(() {
      _saving = true;
      _errorCode = null;
    });
    var saved = false;
    try {
      await ref
          .read(profilesRepositoryProvider)
          .update(self.id, displayName: name);
      saved = true;
    } on Object {
      // The repository checks the same rule, so this is unexpected (a
      // deleted profile, a database error): nothing was written.
      _errorCode = AuthClientErrors.generic;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted || !saved) {
      return;
    }
    requestSync(ref);
    if (!mounted) {
      return;
    }
    context.pop();
  }
}
