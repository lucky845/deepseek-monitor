import 'package:flutter/widgets.dart';

/// The web build is always "in a browser"; this file is only reached on web.

/// Web builds have no in-app webview we can read storage from, so the connect
/// sheet keeps its copy-and-paste flow there.
bool get canCaptureTokenInApp => false;

Future<String?> capturePlatformToken(BuildContext context) async => null;
