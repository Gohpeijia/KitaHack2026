import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

/// Direct Gemini AI service for fridge image analysis and nudge generation.
///
/// Uses exactly 1 API call per scan to stay within free-tier quota (20 RPM).
class GeminiService {
  GeminiService._();
  static final GeminiService instance = GeminiService._();

  static const String _defaultModel = 'gemini-2.5-flash';
  static const String _fallbackModel = 'gemini-2.5-flash-lite';

  GenerativeModel? _model;
  String? _modelName;

  String get _resolvedModelName {
    // Always re-read from env so .env changes take effect on restart.
    final String envModel = (dotenv.env['GEMINI_MODEL'] ?? '').trim();
    final String desired = envModel.isNotEmpty ? envModel : _defaultModel;
    if (_modelName != desired && _modelName != _fallbackModel) {
      _modelName = desired;
      _model = null; // force rebuild with new model
    }
    _modelName ??= desired;
    return _modelName!;
  }

  bool _isUnsupportedModelError(Object error) {
    final String message = error.toString().toLowerCase();
    return message.contains('not found') ||
        message.contains('unsupported') ||
        message.contains('invalid model') ||
        message.contains('model') && message.contains('available');
  }

  void _switchToFallbackModel() {
    if (_resolvedModelName == _fallbackModel) return;
    _modelName = _fallbackModel;
    _model = null;
    debugPrint('Gemini model fallback activated: $_fallbackModel');
  }

  GenerativeModel get _gemini {
    if (_model == null) {
      final String apiKey = dotenv.env['GEMINI_API_KEY'] ?? '';
      if (apiKey.isEmpty || apiKey == 'placeholder') {
        throw Exception(
          'GEMINI_API_KEY not set. Update your .env file with a real key.',
        );
      }
      _model = GenerativeModel(
        model: _resolvedModelName,
        apiKey: apiKey,
        generationConfig: GenerationConfig(
          temperature: 0.15,
          responseMimeType: 'application/json',
        ),
        systemInstruction: Content.text(
          'You are a world-class fridge-inventory vision expert. '
          'You excel at reading product labels, brand logos, and expiry dates on packaging. '
          'Return strict JSON only. Do not hallucinate hidden items.',
        ),
      );
    }
    return _model!;
  }

  // ---------------------------------------------------------------------------
  // Analyze fridge image -> list of food items (1 API call)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> analyzeFridgeImage({
    required Uint8List imageBytes,
    String mimeType = 'image/jpeg',
  }) async {
    try {
      const String prompt =
          'Study this fridge photo carefully, shelf by shelf, door by door. '
          'List EVERY visible food item, drink, condiment, sauce, and container.\n\n'
          'For each item:\n'
          '- Read the LABEL or BRAND printed on the packaging and use that as the name '
          '(e.g. "Kikkoman Soy Sauce", "Dutch Lady Fresh Milk", "Lee Kum Kee Oyster Sauce").\n'
          '- If no brand is readable, describe by appearance (e.g. "Green leafy vegetable", "Brown eggs").\n'
          '- Count visible units for quantity.\n'
          '- Read expiry/best-before dates if printed on label.\n'
          '- Assess condition (fresh/opened/sealed/wilted).\n\n'
          'Return JSON: {"items":[{"name":"Brand Product Name","quantity":1,'
          '"expiry_date":"YYYY-MM-DD" or null,"estimated_expiry_days":3,'
          '"freshness_score":4,"sharing_eligible":false}]}\n\n'
          'Rules:\n'
          '- name: Always non-empty. Use specific brand names when readable.\n'
          '- quantity: int >= 1, count visible units.\n'
          '- expiry_date: "YYYY-MM-DD" if visible on label, otherwise null.\n'
          '- estimated_expiry_days: 0-30, predict using item type + visible condition.\n'
          '- freshness_score: 1 (bad) to 5 (perfect).\n'
          '- sharing_eligible: true if sealed and quantity > 1.\n'
          '- Include ALL visible items (typical fridges have 6-20+ items).\n'
          '- Merge duplicates and count in quantity.\n'
          '- Do NOT skip small items like sauce packets, eggs, or partially hidden items.';

      final GenerateContentResponse response = await _gemini.generateContent(
        <Content>[
          Content.multi(<Part>[
            TextPart(prompt),
            DataPart(mimeType, imageBytes),
          ]),
        ],
      );

      final String text = response.text ?? '';
      debugPrint('Gemini analyzeFridgeImage response: $text');

      final Map<String, dynamic>? parsed = _parseJsonResponse(text);
      if (parsed != null && parsed['items'] is List) {
        final List<dynamic> rawItems = parsed['items'] as List<dynamic>;
        final List<Map<String, dynamic>> normalized = rawItems
            .whereType<Map<String, dynamic>>()
            .map(_normalizeItem)
            .toList();
        if (normalized.isNotEmpty) {
          return <String, dynamic>{'items': normalized};
        }
      }

      return <String, dynamic>{
        'items': <Map<String, dynamic>>[],
        'error': 'AI returned no items. Try a clearer photo.',
      };
    } catch (error) {
      if (_isUnsupportedModelError(error) &&
          _resolvedModelName != _fallbackModel) {
        try {
          _switchToFallbackModel();
          final GenerateContentResponse
          fallbackResponse = await _gemini.generateContent(<Content>[
            Content.multi(<Part>[
              TextPart(
                'Study this fridge photo carefully, shelf by shelf, door by door. '
                'List EVERY visible food item, drink, condiment, sauce, and container. '
                'Return strict JSON with items fields: '
                'name, quantity, expiry_date, estimated_expiry_days, freshness_score, sharing_eligible.',
              ),
              DataPart(mimeType, imageBytes),
            ]),
          ]);
          final Map<String, dynamic>? parsed = _parseJsonResponse(
            fallbackResponse.text ?? '',
          );
          if (parsed != null && parsed['items'] is List) {
            final List<dynamic> rawItems = parsed['items'] as List<dynamic>;
            final List<Map<String, dynamic>> normalized = rawItems
                .whereType<Map<String, dynamic>>()
                .map(_normalizeItem)
                .toList();
            if (normalized.isNotEmpty) {
              return <String, dynamic>{'items': normalized};
            }
          }
        } catch (_) {}
      }
      debugPrint('analyzeFridgeImage error: $error');
      return <String, dynamic>{
        'items': <Map<String, dynamic>>[],
        'error': 'analyzeFridgeImage failed: $error',
      };
    }
  }

  // ---------------------------------------------------------------------------
  // Generate 3 nudge actions from inventory (1 API call)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> generateNudges({
    required List<Map<String, dynamic>> items,
  }) async {
    final List<Map<String, dynamic>> prioritized =
        List<Map<String, dynamic>>.from(items)
          ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
            final int aExp = _toInt(a['estimated_expiry_days'], fallback: 3);
            final int bExp = _toInt(b['estimated_expiry_days'], fallback: 3);
            if (aExp != bExp) return aExp.compareTo(bExp);
            return _toInt(
              a['freshness_score'],
              fallback: 3,
            ).compareTo(_toInt(b['freshness_score'], fallback: 3));
          });
    final List<Map<String, dynamic>> top = prioritized.take(6).toList();

    final String prompt =
        'Create exactly 3 short food-saving actions from this inventory. '
        'Each action must include "title", "why", and duration "~15 min". '
        'Return JSON with an "actions" array. Do not include markdown fences. '
        'Inventory: ${jsonEncode(top)}';

    try {
      final GenerateContentResponse response = await _gemini.generateContent(
        <Content>[Content.text(prompt)],
      );

      final String text = response.text ?? '';
      debugPrint('Gemini generateNudges response: $text');

      final Map<String, dynamic>? parsed = _parseJsonResponse(text);
      if (parsed != null && parsed['actions'] is List) {
        final List<dynamic> rawActions = parsed['actions'] as List<dynamic>;
        if (rawActions.length >= 3) {
          final List<Map<String, dynamic>> actions = <Map<String, dynamic>>[];
          for (final dynamic action in rawActions.take(3)) {
            if (action is Map<String, dynamic>) {
              actions.add(<String, dynamic>{
                'title': ((action['title'] as String?) ?? '').trim(),
                'why': ((action['why'] as String?) ?? '').trim(),
                'duration': '~15 min',
              });
            }
          }
          if (actions.length == 3) {
            return <String, dynamic>{'actions': actions};
          }
        }
      }

      return <String, dynamic>{
        'actions': _fallbackNudges(top),
        'error': 'Model returned invalid nudge output. Fallback nudges used.',
      };
    } catch (error) {
      if (_isUnsupportedModelError(error) &&
          _resolvedModelName != _fallbackModel) {
        try {
          _switchToFallbackModel();
          final GenerateContentResponse fallbackResponse = await _gemini
              .generateContent(<Content>[Content.text(prompt)]);
          final Map<String, dynamic>? parsed = _parseJsonResponse(
            fallbackResponse.text ?? '',
          );
          if (parsed != null && parsed['actions'] is List) {
            final List<dynamic> rawActions = parsed['actions'] as List<dynamic>;
            if (rawActions.length >= 3) {
              final List<Map<String, dynamic>> actions =
                  <Map<String, dynamic>>[];
              for (final dynamic action in rawActions.take(3)) {
                if (action is Map<String, dynamic>) {
                  actions.add(<String, dynamic>{
                    'title': ((action['title'] as String?) ?? '').trim(),
                    'why': ((action['why'] as String?) ?? '').trim(),
                    'duration': '~15 min',
                  });
                }
              }
              if (actions.length == 3) {
                return <String, dynamic>{'actions': actions};
              }
            }
          }
        } catch (_) {}
      }
      debugPrint('generateNudges error: $error');
      return <String, dynamic>{
        'actions': _fallbackNudges(top),
        'error': 'generateNudges failed: $error',
      };
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic>? _parseJsonResponse(String text) {
    final RegExpMatch? fencedMatch = RegExp(
      r'```(?:json)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(text);
    final String raw = fencedMatch != null ? fencedMatch.group(1)! : text;
    try {
      final dynamic parsed = jsonDecode(raw.trim());
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {}

    final int firstBrace = raw.indexOf('{');
    final int lastBrace = raw.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      final String candidate = raw.substring(firstBrace, lastBrace + 1).trim();
      try {
        final dynamic parsed = jsonDecode(candidate);
        if (parsed is Map<String, dynamic>) return parsed;
      } catch (_) {}
    }
    return null;
  }

  int _clamp(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  int _toInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  Map<String, dynamic> _normalizeItem(Map<String, dynamic> raw) {
    String name = ((raw['name'] as String?) ?? 'Unknown Item').trim();
    if (name.isEmpty) name = 'Unknown Item';
    int quantity = _toInt(raw['quantity'], fallback: 1);
    if (quantity < 1) quantity = 1;
    if (quantity > 99) quantity = 99;
    final int expiryDays = _clamp(
      _toInt(raw['estimated_expiry_days'], fallback: 3),
      0,
      30,
    );
    final int freshness = _clamp(
      _toInt(raw['freshness_score'], fallback: 3),
      1,
      5,
    );
    final bool sharingEligible = raw['sharing_eligible'] == true;

    final String? expiryDate =
        (raw['expiry_date'] is String &&
            (raw['expiry_date'] as String).isNotEmpty &&
            raw['expiry_date'] != 'null')
        ? (raw['expiry_date'] as String).trim()
        : null;

    return <String, dynamic>{
      'name': name,
      'quantity': quantity,
      'estimated_expiry_days': expiryDays,
      'freshness_score': freshness,
      'sharing_eligible': sharingEligible,
      if (expiryDate != null) 'expiry_date': expiryDate,
    };
  }

  List<Map<String, dynamic>> _fallbackNudges(List<Map<String, dynamic>> items) {
    final List<Map<String, dynamic>> sorted =
        List<Map<String, dynamic>>.from(items)
          ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
            final int aExp = _toInt(a['estimated_expiry_days'], fallback: 3);
            final int bExp = _toInt(b['estimated_expiry_days'], fallback: 3);
            if (aExp != bExp) return aExp.compareTo(bExp);
            return _toInt(
              a['freshness_score'],
              fallback: 3,
            ).compareTo(_toInt(b['freshness_score'], fallback: 3));
          });
    final String first = sorted.isNotEmpty
        ? sorted[0]['name'] as String
        : 'fridge item';
    final String second = sorted.length > 1
        ? sorted[1]['name'] as String
        : first;
    final String third = sorted.length > 2
        ? sorted[2]['name'] as String
        : second;
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'title': 'Cook $first today',
        'why': 'Shortest expiry first to reduce waste.',
        'duration': '~15 min',
      },
      <String, dynamic>{
        'title': 'Use $second in a quick dish',
        'why': 'Keeps medium-risk food from expiring.',
        'duration': '~15 min',
      },
      <String, dynamic>{
        'title': 'Prep $third for tomorrow',
        'why': 'Prepping now extends usability and avoids spoilage.',
        'duration': '~15 min',
      },
    ];
  }
}
