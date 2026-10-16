/// Whether [a] and [b] are the same moment, or both null, whatever their
/// zone flags (`DateTime.==` also compares UTC against local).
bool sameMoment(DateTime? a, DateTime? b) {
  if (a == null || b == null) {
    return a == b;
  }
  return a.isAtSameMomentAs(b);
}

/// A hash consistent with [sameMoment].
int momentHash(DateTime? moment) => moment?.microsecondsSinceEpoch ?? 0;
