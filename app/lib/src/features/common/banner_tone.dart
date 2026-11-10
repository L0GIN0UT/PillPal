/// The look of a `PillPalBanner`.
enum BannerTone {
  /// Soft apricot card: a hint or a note the user may act on.
  soft,

  /// Neutral card with a blue outline: information, never an error.
  info,

  /// Card with a danger outline and icon: a blocking problem or a failure.
  /// "Missed" is not danger.
  danger,
}
