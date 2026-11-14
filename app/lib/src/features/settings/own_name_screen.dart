import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../data/repositories/validation.dart';
import '../../routing/routes.dart';
import '../auth/auth_fields.dart';
import '../auth/auth_flow_state.dart';
import '../auth/auth_session.dart';
import '../auth/auth_widgets.dart';
import '../common/compact_rows.dart';
import '../common/list_row.dart';
import '../doses/dose_providers.dart';

/// «Ваше имя»: the first row of the account card, with the stored name under
/// the title. The name is the `self` profile's, the one relatives see.
class OwnNameRow extends ConsumerWidget implements NarrowAware {
  /// Creates the row.
  const OwnNameRow({super.key});

  PillPalListRow _row(BuildContext context, String? name) => PillPalListRow(
        key: const Key('settings-own-name'),
        title: AppLocalizations.of(context).settingsOwnName,
        subtitle: name,
        leadingIcon: Icons.badge_outlined,
        onTap: () => unawaited(context.push(AppRoutes.ownName)),
      );

  @override
  double fullLayoutWidth(BuildContext context) {
    final name = ProviderScope.containerOf(context, listen: false)
        .read(selfProfileProvider)
        .valueOrNull
        ?.displayName;
    return _row(context, name).fullLayoutWidth(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(selfProfileProvider).valueOrNull?.displayName;
    return _row(context, name);
  }
}

/// Change of the person's own name (Settings -> Account): one field, checked
/// like at registration (`isPersonName`), written to the `self` profile on
/// the device and sent with the next sync. Until the first pull delivered the
/// profile there is nothing to rename and «Сохранить» stays off.
class OwnNameScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const OwnNameScreen({super.key});

  @override
  ConsumerState<OwnNameScreen> createState() => _OwnNameScreenState();
}

class _OwnNameScreenState extends ConsumerState<OwnNameScreen> {
  late final TextEditingController _name = TextEditingController(
    text: ref.read(selfProfileProvider).valueOrNull?.displayName ?? '',
  );
  String? _errorCode;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final self = ref.watch(selfProfileProvider).valueOrNull;
    return AuthScaffold(
      title: l10n.ownNameTitle,
      actions: [
        BusyButton(
          key: const Key('own-name-save'),
          label: l10n.save,
          busy: _saving,
          enabled: self != null,
          onPressed: _save,
        ),
      ],
      children: [
        AuthErrorBanner(code: _errorCode),
        AuthNameField(
          fieldKey: const Key('own-name-field'),
          controller: _name,
          onChanged: (_) {
            if (_errorCode != null) {
              setState(() => _errorCode = null);
            }
          },
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
    if (!isPersonName(_name.text)) {
      setState(() => _errorCode = AuthClientErrors.invalidName);
      return;
    }
    setState(() {
      _saving = true;
      _errorCode = null;
    });
    try {
      await ref
          .read(profilesRepositoryProvider)
          .update(self.id, displayName: _name.text);
    } on DataException catch (error) {
      // The repository checks the same rule; anything else is unexpected.
      if (mounted) {
        setState(() {
          _saving = false;
          _errorCode = error.code == DataException.validationError
              ? AuthClientErrors.invalidName
              : AuthClientErrors.generic;
        });
      }
      return;
    }
    requestSync(ref);
    if (mounted) {
      context.pop();
    }
  }
}
