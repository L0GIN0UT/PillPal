import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../links/link_providers.dart';
import '../../routing/router.dart';
import '../auth/auth_session.dart';
import 'family_providers.dart';

/// App-wide plumbing of the relatives feature, above the router:
///
/// * invite links opened from outside (app_links) are parsed for this
///   build's region and held; the accept screen is shown once the user is
///   signed in, and it always asks for an explicit confirmation;
/// * the stored links to relatives are refreshed after each successful sync,
///   so "new relative" and role changes show without any push.
class RelativesScope extends ConsumerStatefulWidget {
  /// Wraps [child].
  const RelativesScope({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<RelativesScope> createState() => _RelativesScopeState();
}

class _RelativesScopeState extends ConsumerState<RelativesScope> {
  StreamSubscription<Uri>? _links;
  Uri? _initial;

  @override
  void initState() {
    super.initState();
    unawaited(_listenToLinks());
  }

  Future<void> _listenToLinks() async {
    final source = ref.read(linkSourceProvider);
    _links = source.links.listen(_onLink);
    final initial = await source.initialLink();
    if (initial != null && mounted) {
      _initial = initial;
      _offer(initial);
    }
  }

  void _onLink(Uri uri) {
    // Some platforms replay the launch link on the stream: once is enough.
    if (_initial != null && uri == _initial) {
      _initial = null;
      return;
    }
    _offer(uri);
  }

  void _offer(Uri uri) {
    ref.read(inviteIntakeProvider.notifier).offer(uri.toString());
    _showAcceptScreen();
  }

  void _showAcceptScreen() {
    final signedIn = ref.read(authSessionProvider).valueOrNull ?? false;
    if (signedIn && ref.read(inviteIntakeProvider) != null) {
      unawaited(ref.read(routerProvider).push<void>(AppRoutes.acceptInvite));
    }
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A link opened while signed out waits for the sign-in.
    ref.listen(authSessionProvider.select((s) => s.valueOrNull), (_, signedIn) {
      if (signedIn ?? false) {
        _showAcceptScreen();
      }
    });
    ref.listen(
      syncStatusProvider.select((status) => status.lastSuccessAt),
      (previous, next) {
        final signedIn = ref.read(authSessionProvider).valueOrNull ?? false;
        if (signedIn && next != null && next != previous) {
          unawaited(ref.read(familyActionsProvider).refresh());
        }
      },
    );
    return widget.child;
  }
}
