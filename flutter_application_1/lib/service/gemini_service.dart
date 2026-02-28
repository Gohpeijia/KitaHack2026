import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

/// Direct Gemini AI service for fridge image analysis and nudge generation.
///
/// Rotates through multiple models to maximise free-tier daily quota
/// (each model gets ~20 requests/day on the free plan).
class GeminiService {
  GeminiService._();
  static final GeminiService instance = GeminiService._();

  /// Models to try in order. Each has its own 20 RPD free-tier quota.
  static const List<String> _modelRotation = <String>[
    'gemini-2.5-flash-lite',
    'gemini-2.5-flash',
    'gemini-2.0-flash-lite',
    'gemini-2.0-flash',
  ];

  /// Track which models are quota-exhausted so we skip them.
  final Set<String> _exhaustedModels = <String>{};

  GenerativeModel? _model;
  String? _activeModelName;

  String get _resolvedModelName {
    // If we have an active model that isn't exhausted, use it
    if (_activeModelName != null && !_exhaustedModels.contains(_activeModelName)) {
      return _activeModelName!;
    }
    // Check .env preference first
    final String envModel = (dotenv.env['GEMINI_MODEL'] ?? '').trim();
    if (envModel.isNotEmpty && !_exhaustedModels.contains(envModel)) {
      _activeModelName = envModel;
      _model = null;
      return envModel;
    }
    // Rotate to next available model
    for (final String model in _modelRotation) {
      if (!_exhaustedModels.contains(model)) {
        _activeModelName = model;
        _model = null;
        debugPrint('Gemini: using model $model');
        return model;
      }
    }
    // All exhausted — clear and start over (daily quota may have reset)
    _exhaustedModels.clear();
    _activeModelName = _modelRotation.first;
    _model = null;
    return _activeModelName!;
  }

  bool _isQuotaError(Object error) {
    final String msg = error.toString().toLowerCase();
    return msg.contains('quota') ||
        msg.contains('429') ||
        msg.contains('resource_exhausted') ||
        msg.contains('rate') && msg.contains('limit') ||
        msg.contains('too many requests');
  }

  bool _isUnsupportedModelError(Object error) {
    final String message = error.toString().toLowerCase();
    return message.contains('not found') ||
        message.contains('unsupported') ||
        message.contains('invalid model') ||
        message.contains('model') && message.contains('available');
  }

  /// Mark the current model as quota-exhausted and switch to next available.
  void _rotateToNextModel() {
    final String current = _activeModelName ?? _modelRotation.first;
    _exhaustedModels.add(current);
    _model = null;
    _activeModelName = null; // Will be resolved on next call
    debugPrint('Gemini: model $current exhausted, '
        'exhausted=${_exhaustedModels.length}/${_modelRotation.length}');
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
      // On quota or unsupported-model errors, rotate to the next available model
      if (_isQuotaError(error) || _isUnsupportedModelError(error)) {
        debugPrint('analyzeFridgeImage: ${_resolvedModelName} failed ($error), rotating...');
        _rotateToNextModel();
        // If we still have untried models, retry immediately
        if (_exhaustedModels.length < _modelRotation.length) {
          return analyzeFridgeImage(imageBytes: imageBytes, mimeType: mimeType);
        }
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

  // ---------------------------------------------------------------------------
  // Analyze a barcode -> product name, expiry, freshness (1 API call)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> analyzeBarcode({
    required String barcode,
  }) async {
    final String prompt =
        'A user scanned a product barcode: "$barcode".\n\n'
        'Identify the product and return JSON with these fields:\n'
        '- "name": product name (brand + product, e.g. "Dutch Lady Fresh Milk 1L")\n'
        '- "quantity": 1\n'
        '- "expiry_date": "YYYY-MM-DD" if commonly known, or null\n'
        '- "estimated_expiry_days": estimated shelf life in days (int, 1-365)\n'
        '- "freshness_score": 1-5 (assume new/sealed = 4 or 5)\n'
        '- "category": product category (e.g. "dairy", "snack", "beverage")\n\n'
        'Return ONLY valid JSON, no markdown fences. Example:\n'
        '{"name":"Yakult Original 5-pack","quantity":1,"expiry_date":null,'
        '"estimated_expiry_days":21,"freshness_score":5,"category":"dairy"}';

    try {
      final GenerateContentResponse response = await _gemini.generateContent(
        <Content>[Content.text(prompt)],
      );
      final String text = response.text ?? '';
      debugPrint('Gemini analyzeBarcode response: $text');

      final Map<String, dynamic>? parsed = _parseJsonResponse(text);
      if (parsed != null && parsed['name'] is String) {
        return _normalizeItem(parsed);
      }
      return <String, dynamic>{
        'name': 'Unknown Product',
        'quantity': 1,
        'estimated_expiry_days': 7,
        'freshness_score': 3,
        'error': 'Could not identify product from barcode.',
      };
    } catch (error) {
      if (_isQuotaError(error) || _isUnsupportedModelError(error)) {
        debugPrint('analyzeBarcode: ${_resolvedModelName} failed ($error), rotating...');
        _rotateToNextModel();
        if (_exhaustedModels.length < _modelRotation.length) {
          return analyzeBarcode(barcode: barcode);
        }
      }
      debugPrint('analyzeBarcode error: $error');
      return <String, dynamic>{
        'name': 'Unknown Product',
        'quantity': 1,
        'estimated_expiry_days': 7,
        'freshness_score': 3,
        'error': 'analyzeBarcode failed: $error',
      };
    }
  }

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
      if (_isQuotaError(error) || _isUnsupportedModelError(error)) {
        debugPrint('generateNudges: ${_resolvedModelName} failed ($error), rotating...');
        _rotateToNextModel();
        if (_exhaustedModels.length < _modelRotation.length) {
          return generateNudges(items: items);
        }
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
