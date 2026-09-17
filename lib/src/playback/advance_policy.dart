/// Decision helper for 熄屏不打断下一首 ("do not advance to the next piece while
/// the screen is off"), kept pure so the rule is testable.
///
/// Rules:
///  * with the setting on (the default) the queue always advances, exactly as
///    before;
///  * with the setting off, a piece that ENDS while the screen is off is kept
///    on screen (no automatic advance); the ▶ button then continues with the
///    next piece once the screen is on again;
///  * a piece that ends while the screen is on advances normally even with the
///    setting off.
bool suppressAdvanceForScreenOff({
  required bool advanceWhenScreenOff,
  required bool screenOn,
}) => !advanceWhenScreenOff && !screenOn;
