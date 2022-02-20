import 'dart:convert';

import 'package:cli_util/cli_util.dart';
import 'package:http/http.dart' as http;
import 'package:mason_api/src/jwt_decode.dart';
import 'package:mason_api/src/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';

/// {@template mason_api_exception}
/// Base for all exceptions thrown by [MasonApi].
/// {@endtemplate}
abstract class MasonApiException implements Exception {
  /// {@macro mason_api_exception}
  const MasonApiException({required this.message});

  /// The message associated with the exception.
  final String message;
}

/// {@template mason_api_login_failure}
/// An exception thrown when an error occurs during `login`.
/// {@endtemplate}
class MasonApiLoginFailure extends MasonApiException {
  /// {@macro mason_api_login_failure}
  const MasonApiLoginFailure({required String message})
      : super(message: message);
}

/// {@template mason_api_refresh_failure}
/// An exception thrown when an error occurs during `refresh`.
/// {@endtemplate}
class MasonApiRefreshFailure extends MasonApiException {
  /// {@macro mason_api_refresh_failure}
  const MasonApiRefreshFailure({required String message})
      : super(message: message);
}

/// {@template mason_api_publish_failure}
/// An exception thrown when an error occurs during `publish`.
/// {@endtemplate}
class MasonApiPublishFailure extends MasonApiException {
  /// {@macro mason_api_publish_failure}
  const MasonApiPublishFailure({required String message})
      : super(message: message);
}

/// {@template mason_api}
/// API client for the [package:mason_cli](https://github.com/felangel/mason).
/// {@endtemplate}
class MasonApi {
  /// {@macro mason_api}
  MasonApi({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client() {
    _loadCredentials();
  }

  static const _authority = 'registry.brickhub.dev';
  static const _applicationName = 'mason';
  static const _credentialsFileName = 'mason-credentials.json';

  final http.Client _httpClient;

  /// The location for mason-specific configuration.
  ///
  /// `null` if no config dir could be found.
  final String? _masonConfigDir = () {
    final environment = testEnvironment ?? Platform.environment;
    if (environment.containsKey('_MASON_TEST_CONFIG_DIR')) {
      return environment['_MASON_TEST_CONFIG_DIR'];
    }
    try {
      final configHome = testApplicationConfigHome ?? applicationConfigHome;
      return configHome(_applicationName);
    } catch (_) {
      return null;
    }
  }();

  Credentials? _credentials;

  User? _currentUser;

  /// The current user.
  User? get currentUser => _currentUser;

  /// Log in with the provided [email] and [password].
  Future<User> login({required String email, required String password}) async {
    late final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.https(_authority, 'api/v1/oauth/token'),
        body: json.encode({
          'grant_type': 'password',
          'username': email,
          'password': password,
        }),
      );
    } catch (error) {
      throw MasonApiLoginFailure(message: '$error');
    }

    if (response.statusCode != HttpStatus.ok) {
      var message = 'An unknown error occurred.';
      try {
        final body = json.decode(response.body) as Map<String, dynamic>;
        message = body['message'] as String;
      } catch (_) {}
      throw MasonApiLoginFailure(message: message);
    }

    late final Credentials credentials;
    try {
      credentials = Credentials.fromTokenResponse(
        json.decode(response.body) as Map<String, dynamic>,
      );
      _flushCredentials(credentials);
    } catch (error) {
      throw MasonApiLoginFailure(message: '$error');
    }

    try {
      return _currentUser = credentials.toUser();
    } catch (error) {
      throw MasonApiLoginFailure(message: '$error');
    }
  }

  /// Log out and clear credentials.
  void logout() => _clearCredentials();

  /// Publish universal [bundle] to remote registry.
  Future<void> publish({required List<int> bundle}) async {
    if (_credentials == null) {
      throw const MasonApiPublishFailure(
        message:
            '''User not found. Please make sure you are logged in and try again.''',
      );
    }

    var credentials = _credentials!;
    if (credentials.areExpired) {
      try {
        credentials = await _refresh();
      } on MasonApiRefreshFailure catch (error) {
        throw MasonApiPublishFailure(
          message: 'Refresh failure: ${error.message}',
        );
      }
    }

    final uri = Uri.https(_authority, 'api/v1/bricks');
    final headers = {
      'Authorization': '${credentials.tokenType} ${credentials.accessToken}',
      'Content-Type': 'application/octet-stream',
    };

    late final http.Response response;
    try {
      response = await _httpClient.post(
        uri,
        headers: headers,
        body: bundle,
      );
    } catch (error) {
      throw MasonApiPublishFailure(message: '$error');
    }

    if (response.statusCode != HttpStatus.created) {
      var message = 'An unknown error occurred.';
      try {
        final body = json.decode(response.body) as Map<String, dynamic>;
        message = body['message'] as String;
      } catch (_) {}
      throw MasonApiPublishFailure(message: message);
    }
  }

  /// Attempt to refresh the current credentials and return
  /// refreshed credentials.
  Future<Credentials> _refresh() async {
    late final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.https(_authority, 'api/v1/oauth/token'),
        body: json.encode({
          'grant_type': 'refresh_token',
          'refresh_token': _credentials!.refreshToken,
        }),
      );
    } catch (error) {
      throw MasonApiRefreshFailure(message: '$error');
    }

    if (response.statusCode != HttpStatus.ok) {
      var message = 'An unknown error occurred.';
      try {
        final body = json.decode(response.body) as Map<String, dynamic>;
        message = body['message'] as String;
      } catch (_) {}
      throw MasonApiRefreshFailure(message: message);
    }

    late final Credentials credentials;
    try {
      credentials = Credentials.fromTokenResponse(
        json.decode(response.body) as Map<String, dynamic>,
      );
      _flushCredentials(credentials);
    } catch (error) {
      throw MasonApiRefreshFailure(message: '$error');
    }

    try {
      _currentUser = credentials.toUser();
    } catch (error) {
      throw MasonApiRefreshFailure(message: '$error');
    }

    return credentials;
  }

  void _loadCredentials() {
    final masonConfigDir = _masonConfigDir;
    if (masonConfigDir == null) return;

    final credentialsFile = File(p.join(masonConfigDir, _credentialsFileName));

    if (credentialsFile.existsSync()) {
      try {
        final contents = credentialsFile.readAsStringSync();
        _credentials = Credentials.fromJson(
          json.decode(contents) as Map<String, dynamic>,
        );
        _currentUser = _credentials?.toUser();
      } catch (_) {}
    }
  }

  void _flushCredentials(Credentials credentials) {
    final masonConfigDir = _masonConfigDir;
    if (masonConfigDir == null) return;

    final credentialsFile = File(p.join(masonConfigDir, _credentialsFileName));

    if (!credentialsFile.existsSync()) {
      credentialsFile.createSync(recursive: true);
    }

    credentialsFile.writeAsStringSync(json.encode(credentials.toJson()));
  }

  void _clearCredentials() {
    _credentials = null;
    _currentUser = null;

    final masonConfigDir = _masonConfigDir;
    if (masonConfigDir == null) return;

    final credentialsFile = File(p.join(masonConfigDir, _credentialsFileName));
    if (credentialsFile.existsSync()) {
      credentialsFile.deleteSync(recursive: true);
    }
  }
}

extension on Credentials {
  User toUser() {
    final jwt = accessToken;
    final claims = Jwt.decodeClaims(jwt);

    if (claims == null) throw Exception('Invalid JWT');

    try {
      return User(
        email: claims['email'] as String,
        emailVerified: claims['email_verified'] as bool,
      );
    } catch (_) {
      throw Exception('Malformed Claims');
    }
  }

  /// Whether the credentials have expired.
  bool get areExpired {
    return DateTime.now().add(const Duration(minutes: 1)).isAfter(expiresAt);
  }
}

/// Test environment which should only be used for testing purposes.
Map<String, String>? testEnvironment;

/// Test applicationConfigHome which should only be used for testing purposes.
String Function(String)? testApplicationConfigHome;