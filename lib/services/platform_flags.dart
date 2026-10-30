import 'platform_flags_stub.dart' if (dart.library.io) 'platform_flags_io.dart'
    as impl;

/// Test hook: overrides [runsInBrowser] so both stories can be exercised on
/// any machine. Null means "ask the platform".
bool? debugForceBrowser;

/// True when this code is running inside a browser tab.
bool get runsInBrowser => debugForceBrowser ?? impl.kRunsInBrowser;
