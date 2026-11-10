import '../common/profile_picker_sheet.dart';
import 'profile_context.dart';

/// What a profile picker shows: the people, who is shown now, and who is the
/// account's own profile. Pure, so the chips and the header button agree.
class ProfilePicker {
  const ProfilePicker._({
    required this.items,
    required this.currentId,
    required this.ownId,
  });

  /// Everyone the account may switch to, own first.
  final List<ProfileChipItem> items;

  /// The person shown now.
  final String currentId;

  /// The own profile, or null when it is not among the profiles.
  final String? ownId;

  /// The name of the person shown now.
  String get currentLabel =>
      items.firstWhere((item) => item.id == currentId).label;

  /// The picker for [profiles] with [selected] chosen (null: the own
  /// profile), or null while there is only one person to show. [meLabel]
  /// names the own profile.
  static ProfilePicker? of(
    List<ProfileAccess>? profiles,
    String? selected, {
    required String meLabel,
  }) {
    if (profiles == null || profiles.length < 2) {
      return null;
    }
    final own = profiles.where((a) => a.isOwnSelf).map((a) => a.id).firstOrNull;
    final current = selected != null && profiles.any((a) => a.id == selected)
        ? selected
        : own ?? profiles.first.id;
    return ProfilePicker._(
      items: [
        for (final access in profiles)
          ProfileChipItem(
            id: access.id,
            label: access.isOwnSelf ? meLabel : access.profile.displayName,
          ),
      ],
      currentId: current,
      ownId: own,
    );
  }

  /// The value to store as the selected profile for [id]: null for the own.
  String? selectionOf(String id) => id == ownId ? null : id;
}
