import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Microsoft sign-in for the MERCHANT's OneDrive, using the device-code flow:
/// the app shows a short code, the merchant types it at microsoft.com/devicelogin
/// on any device, and the tokens land here.
///
/// SPARK MODE SECURITY: this runs ONLY inside the merchant area of the app, on
/// the merchant's own device. The refresh token lives in the device keychain
/// (flutter_secure_storage). Customer devices never touch any of this.
class OneDriveAuth {
  OneDriveAuth._();
  static final OneDriveAuth instance = OneDriveAuth._();

  static const _tenant = 'common';
  static const _scope =
      'https://graph.microsoft.com/Files.ReadWrite offline_access';
  static const _base = 'https://login.microsoftonline.com/$_tenant/oauth2/v2.0';

  static const _storage = FlutterSecureStorage();
  static const _kClientId = 'onedrive_client_id';
  static const _kRefreshToken = 'onedrive_refresh_token';
  static const _kAccount = 'onedrive_account';

  String? _accessToken;
  DateTime? _accessExpiry;

  Future<bool> get isConnected async =>
      (await _storage.read(key: _kRefreshToken)) != null;

  Future<String?> get connectedAccount => _storage.read(key: _kAccount);

  Future<void> disconnect() async {
    _accessToken = null;
    _accessExpiry = null;
    await _storage.delete(key: _kRefreshToken);
    await _storage.delete(key: _kAccount);
  }

  /// Starts the device-code flow. Returns the code + URL to show the merchant.
  /// [clientId] is the (free) Azure app registration id — entered once.
  Future<({String userCode, String verificationUri, String deviceCode, int interval, int expiresIn})>
      startDeviceCode(String clientId) async {
    final res = await http.post(
      Uri.parse('$_base/devicecode'),
      body: {'client_id': clientId.trim(), 'scope': _scope},
    );
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['device_code'] == null) {
      throw StateError(
          json['error_description'] as String? ?? 'Device code request failed');
    }
    await _storage.write(key: _kClientId, value: clientId.trim());
    return (
      userCode: json['user_code'] as String,
      verificationUri:
          json['verification_uri'] as String? ?? 'https://microsoft.com/devicelogin',
      deviceCode: json['device_code'] as String,
      interval: (json['interval'] as num?)?.toInt() ?? 5,
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 900,
    );
  }

  /// Polls until the merchant finishes signing in (or the code expires).
  /// Returns null on success, or an error message.
  Future<String?> waitForSignIn({
    required String deviceCode,
    required int interval,
    required int expiresIn,
  }) async {
    final clientId = await _storage.read(key: _kClientId);
    if (clientId == null) return 'Connection was reset — start again.';
    final deadline = DateTime.now().add(Duration(seconds: expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: interval));
      final res = await http.post(Uri.parse('$_base/token'), body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': clientId,
        'device_code': deviceCode,
      });
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final err = json['error'] as String?;
      if (err == 'authorization_pending') continue;
      if (err == 'slow_down') continue;
      if (err != null) {
        return (json['error_description'] as String?) ?? err;
      }
      await _saveTokens(json);
      return null;
    }
    return 'The sign-in code expired — try again.';
  }

  Future<void> _saveTokens(Map<String, dynamic> tokenJson) async {
    _accessToken = tokenJson['access_token'] as String?;
    _accessExpiry = DateTime.now()
        .add(Duration(seconds: (tokenJson['expires_in'] as num?)?.toInt() ?? 3600));
    final refresh = tokenJson['refresh_token'] as String?;
    if (refresh != null) {
      await _storage.write(key: _kRefreshToken, value: refresh);
    }
    // Best-effort: remember which account connected (from the Graph /me call).
    try {
      final me = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      final mj = jsonDecode(me.body) as Map<String, dynamic>;
      final who = (mj['userPrincipalName'] ?? mj['displayName'])?.toString();
      if (who != null) await _storage.write(key: _kAccount, value: who);
    } catch (_) {/* cosmetic only */}
  }

  /// Valid access token, refreshing if needed. Throws if not connected.
  Future<String> accessToken() async {
    if (_accessToken != null &&
        _accessExpiry != null &&
        DateTime.now().isBefore(_accessExpiry!.subtract(const Duration(minutes: 2)))) {
      return _accessToken!;
    }
    final clientId = await _storage.read(key: _kClientId);
    final refresh = await _storage.read(key: _kRefreshToken);
    if (clientId == null || refresh == null) {
      throw StateError('OneDrive is not connected.');
    }
    final res = await http.post(Uri.parse('$_base/token'), body: {
      'grant_type': 'refresh_token',
      'client_id': clientId,
      'refresh_token': refresh,
      'scope': _scope,
    });
    if (res.statusCode != 200) {
      debugPrint('[OneDriveAuth] refresh failed: ${res.body}');
      throw StateError('OneDrive session expired — reconnect in Cloud sync.');
    }
    await _saveTokens(jsonDecode(res.body) as Map<String, dynamic>);
    return _accessToken!;
  }
}
