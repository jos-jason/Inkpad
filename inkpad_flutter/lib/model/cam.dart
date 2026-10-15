/// Machine settings for G-code, kept with the drawing. Lengths in points
/// (like the drawing); speeds in millimetres per minute.
class CamSettings {
  double feed, plunge, stepDown, safeHeight, stepOver;
  int spindle;

  /// Holding tabs on through-cuts, so parts stay put until the end.
  bool tabs;
  int tabCount;
  double tabWidth, tabHeight;

  /// Climb milling (else conventional, the gentler default for hobby
  /// machines).
  bool climb;

  CamSettings({
    this.feed = 1000,
    this.plunge = 300,
    this.stepDown = 2 * 72 / 25.4,
    this.safeHeight = 5 * 72 / 25.4,
    this.stepOver = 0.45,
    this.spindle = 18000,
    this.tabs = true,
    this.tabCount = 4,
    this.tabWidth = 6 * 72 / 25.4,
    this.tabHeight = 2 * 72 / 25.4,
    this.climb = false,
  });

  Map<String, dynamic> toJson() => {
        'feed': feed,
        'plunge': plunge,
        'stepDown': stepDown,
        'safe': safeHeight,
        'stepOver': stepOver,
        'spindle': spindle,
        'tabs': tabs,
        'tabCount': tabCount,
        'tabWidth': tabWidth,
        'tabHeight': tabHeight,
        'climb': climb,
      };

  factory CamSettings.fromJson(Map<String, dynamic> j) {
    final d = CamSettings();
    double n(String k, double v) => (j[k] as num?)?.toDouble() ?? v;
    return CamSettings(
      feed: n('feed', d.feed),
      plunge: n('plunge', d.plunge),
      stepDown: n('stepDown', d.stepDown),
      safeHeight: n('safe', d.safeHeight),
      stepOver: n('stepOver', d.stepOver),
      spindle: (j['spindle'] as num?)?.toInt() ?? d.spindle,
      tabs: j['tabs'] as bool? ?? d.tabs,
      tabCount: (j['tabCount'] as num?)?.toInt() ?? d.tabCount,
      tabWidth: n('tabWidth', d.tabWidth),
      tabHeight: n('tabHeight', d.tabHeight),
      climb: j['climb'] as bool? ?? d.climb,
    );
  }
}
