import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown when a DeepSeek vision request cannot be completed.
///
/// The message is always user-safe. It never carries the API key, the raw
/// response body, or anything read off a scanned sheet -- callers may show it
/// directly to a user.
class DeepSeekVisionException implements Exception {
  const DeepSeekVisionException(this.message, {this.statusCode});

  final String message;

  /// HTTP status, when the failure came back from the API rather than the
  /// network. Null for timeouts and connection failures.
  final int? statusCode;

  @override
  String toString() => 'DeepSeekVisionException: $message';
}

/// A minimal OpenAI-compatible client for DeepSeek's vision model.
///
/// Two constraints are baked into this class because they are easy to get
/// wrong from the outside:
///
/// * Only `deepseek-flash` accepts images. The pro model rejects any request
///   containing an image block with a 400, and `deepseek-v4-flash-vision-exp`
///   is a retired alias that fails outright.
/// * Images travel as base64 data URLs inside a `user` message. The API caps
///   each image at roughly 1024 tokens and resizes toward ~1300x1300 px, so
///   sending a full-resolution photo costs the same as a modest crop.
///
/// The key is supplied through `--dart-define=DEEPSEEK_API_KEY=...` (see
/// `dart_defines/README.md`) and is never hardcoded. With no key configured,
/// [isConfigured] is false and every call throws, so callers can hide or
/// disable a feature rather than fail at the moment of use.
class DeepSeekVisionService {
  DeepSeekVisionService({
    http.Client? client,
    String? apiKey,
    String? baseUrl,
    String? model,
    Duration? timeout,
  })  : _client = client ?? http.Client(),
        _apiKey = apiKey ?? const String.fromEnvironment('DEEPSEEK_API_KEY'),
        _baseUrl = baseUrl ?? 'https://api.deepseek.com',
        _model = model ?? 'deepseek-flash',
        _timeout = timeout ?? const Duration(seconds: 60),
        _ownsClient = client == null;

  final http.Client _client;
  final String _apiKey;
  final String _baseUrl;
  final String _model;
  final Duration _timeout;
  final bool _ownsClient;

  /// Whether an API key was actually supplied at build time. The model name
  /// is overridable ([model]) so a future local server can be pointed at with
  /// the same client -- only [baseUrl] and [model] change.
  bool get isConfigured => _apiKey.trim().isNotEmpty;

  /// Sends one image plus a prompt and returns the model's reply as text.
  ///
  /// [temperature] defaults to 0: these are verdicts about a scanned sheet,
  /// and a repeatable answer is worth more than a creative one.
  ///
  /// Throws [DeepSeekVisionException] on any failure, including a missing key.
  /// Never throws a raw network or JSON error.
  Future<String> askAboutImage({
    required Uint8List imageBytes,
    required String prompt,
    String mimeType = 'image/jpeg',
    int maxTokens = 512,
    double temperature = 0,
  }) async {
    if (!isConfigured) {
      throw const DeepSeekVisionException(
        'No DeepSeek API key is configured for this build.',
      );
    }
    if (imageBytes.isEmpty) {
      throw const DeepSeekVisionException('There was no image to send.');
    }

    final uri = Uri.parse('$_baseUrl/v1/chat/completions');
    final payload = jsonEncode(<String, dynamic>{
      'model': _model,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': prompt},
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{
                'url': 'data:$mimeType;base64,${base64Encode(imageBytes)}',
              },
            },
          ],
        },
      ],
    });

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: payload,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const DeepSeekVisionException(
        'The model did not respond in time. It will be retried.',
      );
    } catch (_) {
      // Deliberately swallows the transport error: it can carry the request
      // URI and headers, and none of that belongs in a user-facing message.
      throw const DeepSeekVisionException(
        'Could not reach the model. Check the network connection.',
      );
    }

    if (response.statusCode != 200) {
      throw DeepSeekVisionException(
        _describeStatus(response.statusCode),
        statusCode: response.statusCode,
      );
    }

    return _extractContent(response.body);
  }

  /// Releases the underlying client, and only when this instance created it.
  /// Closing a caller-injected client would break whatever else shares it.
  void dispose() {
    if (_ownsClient) _client.close();
  }

  static String _extractContent(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const DeepSeekVisionException('The model returned an unreadable reply.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const DeepSeekVisionException('The model returned an unreadable reply.');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const DeepSeekVisionException('The model returned no answer.');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw const DeepSeekVisionException('The model returned an empty answer.');
    }
    return content.trim();
  }

  /// Maps a status code to a message a person can act on. The response body is
  /// never included -- it can echo the request back.
  static String _describeStatus(int status) {
    switch (status) {
      case 400:
        return 'The request was rejected. The model may not accept images.';
      case 401:
      case 403:
        return 'The model rejected the API key.';
      case 402:
        return 'The DeepSeek account is out of credit.';
      case 429:
        return 'The model is rate limiting requests. Try again shortly.';
      default:
        if (status >= 500) {
          return 'The model service is having trouble. Try again shortly.';
        }
        return 'The request failed (HTTP $status).';
    }
  }
}
