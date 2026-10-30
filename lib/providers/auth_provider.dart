import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two credential paths, per the product brief:
///  - platform token  → scraped from the official login flow (full usage data)
///  - API key         → official /user/balance only (balance, no per-model usage)
enum AuthMode { none, platformToken, apiKey }

class AuthProvider extends ChangeNotifier {
  static const _kToken = 'token';
  static const _kApiKey = 'api_key';
  static const _kEmail = 'email';
  static const _kPersist = 'persist_credentials';

  String? _token;
  String? _apiKey;
  String? _email;
  String? _error;
  bool _persist = true;

  bool get isLoggedIn =>
      (_token != null && _token!.isNotEmpty) ||
      (_apiKey != null && _apiKey!.isNotEmpty);
  bool get hasPlatformToken => _token != null && _token!.isNotEmpty;
  bool get hasApiKey => _apiKey != null && _apiKey!.isNotEmpty;
  AuthMode get mode => hasPlatformToken
      ? AuthMode.platformToken
      : (hasApiKey ? AuthMode.apiKey : AuthMode.none);

  String? get token => _token;
  String? get apiKey => _apiKey;
  String? get email => _email;
  String? get error => _error;

  /// When false the credentials live in memory for this session only and are
  /// never written to disk. The UI states which of the two is in effect, and
  /// the claim on screen is produced here rather than assumed.
  bool get persistCredentials => _persist;

  void setError(String? e) {
    _error = e;
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _persist = prefs.getBool(_kPersist) ?? true;
    if (_persist) {
      _token = prefs.getString(_kToken);
      _apiKey = prefs.getString(_kApiKey);
      _email = prefs.getString(_kEmail);
    } else {
      _token = null;
      _apiKey = null;
      _email = null;
    }
    notifyListeners();
  }

  /// Turning persistence off also erases anything already written, so the
  /// promise on screen matches what is on disk.
  Future<void> setPersist(bool value) async {
    _persist = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPersist, value);
    if (!value) {
      await prefs.remove(_kToken);
      await prefs.remove(_kApiKey);
      await prefs.remove(_kEmail);
    }
    notifyListeners();
  }

  void setToken(String token) {
    _token = token;
    _error = null;
    if (_persist) {
      SharedPreferences.getInstance().then((p) => p.setString(_kToken, token));
    }
    notifyListeners();
  }

  void setApiKey(String key) {
    _apiKey = key;
    _error = null;
    if (_persist) {
      SharedPreferences.getInstance().then((p) => p.setString(_kApiKey, key));
    }
    notifyListeners();
  }

  void setEmail(String email) {
    _email = email;
    if (_persist) {
      SharedPreferences.getInstance().then((p) => p.setString(_kEmail, email));
    }
    notifyListeners();
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kApiKey);
    _token = null;
    _apiKey = null;
    notifyListeners();
  }
}
