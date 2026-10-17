import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/config.dart';
import '../data/providers.dart';
import 'invite_link.dart';

/// The link hosts of both regions and the region this build serves.
final linkConfigProvider = Provider<LinkConfig>(
  (ref) => LinkConfig.fromEnvironment(
    region: ref.watch(apiConfigProvider).region,
  ),
);

/// Where verified https links reach the app: the link that launched it and
/// the ones that arrive while it runs. Tests replace it with a fake.
abstract interface class LinkSource {
  /// The link that started the app, if any.
  Future<Uri?> initialLink();

  /// Links that arrive while the app runs.
  Stream<Uri> get links;
}

/// [LinkSource] over the `app_links` plugin (Android App Links, iOS
/// universal links).
class AppLinksSource implements LinkSource {
  /// Creates the source.
  AppLinksSource() : _appLinks = AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> initialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get links => _appLinks.uriLinkStream;
}

/// The platform link source.
final linkSourceProvider = Provider<LinkSource>((ref) => AppLinksSource());

/// What an opened or pasted link led to: a token to preview, or the reason
/// the link is refused. The token is a bearer capability: it is never put
/// into a URL, a log or [toString].
class InviteIntake {
  /// Creates an intake from a parsed link.
  const InviteIntake(this.result);

  /// The parse result.
  final InviteLinkResult result;

  @override
  String toString() => 'InviteIntake($result)';
}

/// The link waiting to be shown on the accept screen; null when none.
final inviteIntakeProvider =
    NotifierProvider<InviteIntakeNotifier, InviteIntake?>(
  InviteIntakeNotifier.new,
);

/// Holds the latest invite link until the accept screen takes it.
class InviteIntakeNotifier extends Notifier<InviteIntake?> {
  @override
  InviteIntake? build() => null;

  /// Parses [raw] (a link or a pasted message) for this build's region and
  /// holds the result; returns it.
  InviteLinkResult offer(String raw) {
    final result = parseInviteLink(raw, ref.read(linkConfigProvider));
    state = InviteIntake(result);
    return result;
  }

  /// Hands the held link to the accept screen and forgets it.
  InviteIntake? take() {
    final held = state;
    state = null;
    return held;
  }
}

/// Hands [text] (an invite message) to the system share sheet.
typedef TextSharer = Future<void> Function(String text);

/// The system share sheet; tests replace it.
final textSharerProvider = Provider<TextSharer>(
  (ref) => (text) async {
    await SharePlus.instance.share(ShareParams(text: text));
  },
);
