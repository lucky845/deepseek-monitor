import 'package:flutter/material.dart';

import 'credential_facts.dart';
import 'platform_flags.dart';
import 'token_capture_stub.dart' if (dart.library.io) 'token_capture_io.dart'
    as impl;

// The browser story lives in platform_flags.dart (the service layer needs the
// same answer); re-exported so callers and tests keep one import.
export 'platform_flags.dart' show debugForceBrowser, runsInBrowser;

/// Test hook: overrides [canCaptureTokenInApp] so both the native and the
/// manual UI can be exercised on any machine. Null means "ask the platform".
bool? debugForceTokenCapture;

/// The credential story for this platform, derived rather than hand-written.
CredentialFacts get platformCredentialFacts => credentialFacts(
      inBrowser: runsInBrowser,
      canCaptureInApp: canCaptureTokenInApp,
    );

/// True when this build can log in to DeepSeek inside the app and read the
/// session token itself (Android, iOS, macOS, Windows).
bool get canCaptureTokenInApp =>
    debugForceTokenCapture ?? impl.canCaptureTokenInApp;

/// Opens the official sign-in page in an in-app webview, lets the user log in
/// on DeepSeek's own page, and returns the *verified* session token. Returns
/// null when the platform cannot do this, or the user backed out.
Future<String?> capturePlatformToken(BuildContext context) =>
    impl.capturePlatformToken(context);
