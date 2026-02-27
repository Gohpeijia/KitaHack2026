import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../service/gemini_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const FridgeGuardianApp());
}

enum DemoStep { home, scan, processing, inventory, suggestions, dashboard }

class FoodItem {
  FoodItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.expiryDate,
    required this.freshnessScore,
    this.consumed = false,
  });

  final String id;
  String name;
  int quantity;
  DateTime expiryDate;
  int freshnessScore;
  bool consumed;
}

class DemoStats {
  int totalScans = 0;
  int totalItemsSaved = 0;
  double co2eAvoidedKg = 0;
}

class FridgeGuardianApp extends StatefulWidget {
  const FridgeGuardianApp({super.key});

  @override
  State<FridgeGuardianApp> createState() => _FridgeGuardianAppState();
}

class _FridgeGuardianAppState extends State<FridgeGuardianApp> {
  bool _demoMode = true;
  bool _processing = false;
  DemoStep _step = DemoStep.home;
  String? _selectedImageLabel;
  XFile? _selectedImageFile;
  String? _uid;
  String? _liveStatusMessage;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _liveInventorySubscription;
  StreamSubscription<RemoteMessage>? _fcmForegroundSubscription;
  StreamSubscription<RemoteMessage>? _fcmOpenedSubscription;
  bool? _fcmConnected;
    final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, _QuickEditResult> _manualEditOverrides =
      <String, _QuickEditResult>{};
  List<String> _liveSuggestions = <String>[];
  bool _loadingLiveSuggestions = false;
    DateTime? _geminiQuotaBlockedUntil;
  Timer? _quotaCooldownTimer;
  Uint8List? _lastScanImageBytes;
  String? _lastUrgentSignature;
  final DemoStats _stats = DemoStats();
  final List<FoodItem> _inventory = <FoodItem>[];
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    unawaited(_initLocalNotifications());
    unawaited(_initInAppPushNotifications());
    unawaited(_warmStartUrgentDashboardFeed());
  }

  Future<void> _initLocalNotifications() async {
    if (kIsWeb) return;
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosInit =
        DarwinInitializationSettings();
    const InitializationSettings initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
      macOS: iosInit,
    );
    await _localNotifications.initialize(initSettings);
  }

  @override
  void dispose() {
    _liveInventorySubscription?.cancel();
    _fcmForegroundSubscription?.cancel();
    _fcmOpenedSubscription?.cancel();
    _quotaCooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _initInAppPushNotifications() async {
    if (Firebase.apps.isEmpty) return;
    try {
      final FirebaseMessaging messaging = FirebaseMessaging.instance;
      final NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      final bool allowed =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!allowed) {
        if (!mounted) return;
        setState(() {
          _fcmConnected = false;
        });
        return;
      }
      await messaging.subscribeToTopic('fridgeguardian-alerts');
      if (mounted) {
        setState(() {
          _fcmConnected = true;
        });
      }

      _fcmForegroundSubscription =
          FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final String title =
            message.notification?.title?.trim().isNotEmpty == true
            ? message.notification!.title!.trim()
            : 'Urgent Food Alert';
        final String body =
            message.notification?.body?.trim().isNotEmpty == true
            ? message.notification!.body!.trim()
            : 'You have items requiring urgent action.';
        final String full = '$title: $body';
        if (!mounted) return;
        setState(() {
          _liveStatusMessage = full;
        });
        _showSnack(full, isError: true);
      });

      _fcmOpenedSubscription =
          FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        if (!mounted) return;
        _setStep(DemoStep.inventory);
        _showSnack('Opened from alert. Review urgent items now.', isError: true);
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _fcmConnected = false;
        });
      }
      debugPrint('FCM setup skipped: $error');
    }
  }

  Widget _buildFcmConnectionIndicator() {
    final ThemeData theme = Theme.of(context);
    final bool checking = _fcmConnected == null;
    final bool connected = _fcmConnected == true;

    final String label = checking
        ? 'FCM Checking...'
        : connected
            ? 'FCM Connected'
            : 'FCM Not Connected';
    final IconData icon = checking
        ? Icons.sync_rounded
        : connected
            ? Icons.notifications_active_rounded
            : Icons.notifications_off_rounded;
    final Color background = checking
        ? theme.colorScheme.surfaceContainerHigh
        : connected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.errorContainer;
    final Color foreground = checking
        ? theme.colorScheme.onSurfaceVariant
        : connected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onErrorContainer;

    return Card(
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _warmStartUrgentDashboardFeed() async {
    try {
      if (Firebase.apps.isEmpty) return;
      User? user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) return;
      _uid = user.uid;
      _subscribeToLiveInventory();
    } catch (error) {
      debugPrint('Warm-start urgent feed skipped: $error');
    }
  }

  List<FoodItem> _urgentRedItems() {
    final List<FoodItem> urgent = _inventory
        .where((FoodItem item) => !item.consumed && _isAtRisk(item))
        .toList();
    urgent.sort((FoodItem a, FoodItem b) =>
        _daysToExpiry(a).compareTo(_daysToExpiry(b)));
    return urgent;
  }

  void _emitUrgentActionAlert({bool force = false}) {
    final List<FoodItem> urgent = _urgentRedItems();
    if (urgent.isEmpty) return;
    final String signature = urgent
        .map((FoodItem item) => '${item.id}:${item.quantity}:${_daysToExpiry(item)}')
        .join('|');
    if (!force && signature == _lastUrgentSignature) return;
    _lastUrgentSignature = signature;

    final String names = urgent.take(3).map((FoodItem item) => item.name).join(', ');
    final String message =
        'Urgent Action: ${urgent.length} red item(s) expiring soon ($names).';
    if (!mounted) return;
    setState(() {
      _liveStatusMessage = message;
    });
    unawaited(_showUrgentLocalNotification(message));
    _showSnack(message, isError: true);
  }

  void _simulateUrgentPushPreview() {
    final List<FoodItem> urgent = _urgentRedItems();
    final String message = urgent.isEmpty
        ? 'Test Alert: No red items right now. Run a scan to generate urgent alerts.'
        : 'Test Alert: ${urgent.length} red item(s) need urgent action.';
    if (!mounted) return;
    setState(() {
      _liveStatusMessage = message;
    });
    _showSnack(message, isError: true);
    if (urgent.isNotEmpty) {
      _setStep(DemoStep.inventory);
    }
  }

  Future<void> _showUrgentLocalNotification(String message) async {
    if (kIsWeb) return;
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'urgent_food_alerts',
      'Urgent Food Alerts',
      channelDescription: 'Notifications for urgent expiring food items',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'urgent-food-alert',
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails();
    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );
    await _localNotifications.show(
      1001,
      'FridgeGuardian Alert',
      message,
      details,
    );
  }

  void _setStep(DemoStep step) {
    setState(() => _step = step);
  }

  DemoStep? _previousStep(DemoStep step) {
    switch (step) {
      case DemoStep.home:
        return null;
      case DemoStep.scan:
        return DemoStep.home;
      case DemoStep.processing:
        return DemoStep.scan;
      case DemoStep.inventory:
        return DemoStep.processing;
      case DemoStep.suggestions:
        return DemoStep.inventory;
      case DemoStep.dashboard:
        return DemoStep.suggestions;
    }
  }

  void _goBackStep() {
    final DemoStep? previous = _previousStep(_step);
    if (previous != null) {
      _setStep(previous);
    }
  }

  Future<void> _toggleDemoMode(bool enabled) async {
    if (enabled) {
      _liveInventorySubscription?.cancel();
      if (!mounted) return;
      setState(() {
        _demoMode = true;
        _liveStatusMessage = null;
        _liveSuggestions = <String>[];
      });
      return;
    }
    final bool ready = await _ensureLiveModeReady();
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _demoMode = true;
      });
      _showSnack(
        'Live mode unavailable. Staying in Demo Mode.',
        isError: true,
      );
      return;
    }
    _subscribeToLiveInventory();
    setState(() {
      _demoMode = false;
      _liveStatusMessage = null;
      _liveSuggestions = <String>[];
    });
  }

  Future<void> _pickImage() async {
    if (_demoMode) {
      setState(() {
        _selectedImageFile = null;
        _selectedImageLabel = 'mock_fridge_photo.jpg';
      });
      return;
    }
    try {
      final XFile? picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1536,
        maxHeight: 1536,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      final Uint8List bytes = await picked.readAsBytes();
      setState(() {
        _selectedImageFile = picked;
        _selectedImageLabel = picked.name;
        _lastScanImageBytes = bytes;
      });
    } catch (_) {
      _showSnack('Image picker failed in Live Mode.', isError: true);
    }
  }

  List<FoodItem> _buildDemoInventory() {
    final DateTime now = DateTime.now();
    return <FoodItem>[
      FoodItem(
        id: 'milk',
        name: 'Milk',
        quantity: 1,
        expiryDate: now.add(const Duration(days: 1)),
        freshnessScore: 2,
      ),
      FoodItem(
        id: 'spinach',
        name: 'Spinach',
        quantity: 1,
        expiryDate: now,
        freshnessScore: 1,
      ),
      FoodItem(
        id: 'tomatoes',
        name: 'Tomatoes',
        quantity: 4,
        expiryDate: now.add(const Duration(days: 2)),
        freshnessScore: 3,
      ),
      FoodItem(
        id: 'eggs',
        name: 'Eggs',
        quantity: 6,
        expiryDate: now.add(const Duration(days: 6)),
        freshnessScore: 4,
      ),
    ];
  }

  void _startDemoProcessing() {
    if (!_demoMode || _processing) return;
    setState(() {
      _processing = true;
      _step = DemoStep.processing;
    });
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted || !_processing) return;
      setState(() {
        _inventory
          ..clear()
          ..addAll(_buildDemoInventory());
        _lastScanImageBytes = null; // demo has no real image
        _stats.totalScans += 1;
        _processing = false;
        _step = DemoStep.inventory;
      });
      _emitUrgentActionAlert(force: true);
    });
  }

  int _daysToExpiry(FoodItem item) {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTime expiry = DateUtils.dateOnly(item.expiryDate);
    return expiry.difference(today).inDays;
  }

  bool _isAtRisk(FoodItem item) =>
      !item.consumed && (_daysToExpiry(item) <= 2 || item.freshnessScore <= 2);

  Color _riskColor(FoodItem item) {
    if (item.consumed) return const Color(0xFF1A1F2B);
    if (_isAtRisk(item)) return const Color(0xFF4B1F23);
    if (_daysToExpiry(item) <= 4) return const Color(0xFF4A321E);
    return const Color(0xFF1E2B33);
  }

  Future<void> _quickEditItem(
    String itemId,
    String newName,
    int newQuantity, {
    DateTime? newExpiryDate,
    int? newFreshnessScore,
  }) async {
    final int i = _inventory.indexWhere((FoodItem item) => item.id == itemId);
    final int safeQuantity = newQuantity < 1 ? 1 : newQuantity;
    final String trimmedName = newName.trim();
    final String fallbackName = i >= 0 ? _inventory[i].name : 'Unknown Item';
    final String safeName = trimmedName.isEmpty ? fallbackName : trimmedName;
    final DateTime safeExpiryDate =
        DateUtils.dateOnly(newExpiryDate ?? (i >= 0 ? _inventory[i].expiryDate : DateTime.now()));
    final int safeFreshness =
        (newFreshnessScore ?? (i >= 0 ? _inventory[i].freshnessScore : 3)).clamp(1, 5);
    setState(() {
      if (i >= 0) {
        _inventory[i].name = safeName;
        _inventory[i].quantity = safeQuantity;
        _inventory[i].expiryDate = safeExpiryDate;
        _inventory[i].freshnessScore = safeFreshness;
      }
      _manualEditOverrides[itemId] = _QuickEditResult(
        safeName,
        safeQuantity,
        safeExpiryDate,
        safeFreshness,
      );
    });
    _emitUrgentActionAlert();
    if (_demoMode || _uid == null) return;
    try {
      final String uid = _uid!;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inventory')
          .doc(itemId)
          .set(<String, dynamic>{
        'name': safeName,
        'quantity': safeQuantity,
        'estimated_expiry': Timestamp.fromDate(safeExpiryDate),
        'freshness_score': safeFreshness,
      }, SetOptions(merge: true));
    } catch (_) {
      _showSnack('Quick edit synced locally only.', isError: true);
    }
  }

  DateTime _parseDateOrFallback(String input, DateTime fallback) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) return DateUtils.dateOnly(fallback);

    final DateTime? direct = DateTime.tryParse(trimmed);
    if (direct != null) return DateUtils.dateOnly(direct);

    final RegExpMatch? dmy =
        RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(trimmed);
    if (dmy != null) {
      final int day = int.tryParse(dmy.group(1) ?? '') ?? 0;
      final int month = int.tryParse(dmy.group(2) ?? '') ?? 0;
      final int year = int.tryParse(dmy.group(3) ?? '') ?? 0;
      if (year >= 2000 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        final DateTime parsed = DateTime(year, month, day);
        if (parsed.year == year && parsed.month == month && parsed.day == day) {
          return DateUtils.dateOnly(parsed);
        }
      }
    }
    return DateUtils.dateOnly(fallback);
  }

  String _formatDateDmy(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _openQuickEditDialog(FoodItem item) async {
    final TextEditingController nameController =
        TextEditingController(text: item.name);
    final TextEditingController qtyController =
        TextEditingController(text: item.quantity.toString());
    final TextEditingController expiryController = TextEditingController(
      text: _formatDateDmy(item.expiryDate),
    );
    final TextEditingController freshnessController =
        TextEditingController(text: item.freshnessScore.toString());
    final _QuickEditResult? result = await showDialog<_QuickEditResult>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext dialogContext, StateSetter setDialogState) {
          return AlertDialog(
            title: const Text('Edit Item Details'),
            content: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: nameController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: qtyController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Quantity'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: expiryController,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Expiry Date (DD/MM/YYYY)',
                        suffixIcon: IconButton(
                          tooltip: 'Pick Date',
                          icon: const Icon(Icons.calendar_today_rounded),
                          onPressed: () async {
                            final DateTime initial = _parseDateOrFallback(
                              expiryController.text,
                              item.expiryDate,
                            );
                            final DateTime? picked = await showDatePicker(
                              context: dialogContext,
                              initialDate: initial,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (picked == null) return;
                            setDialogState(() {
                              expiryController.text = _formatDateDmy(picked);
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: freshnessController,
                      decoration: const InputDecoration(
                        labelText: 'Freshness (1-5)',
                        helperText: '1 = poor, 5 = excellent',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final int parsedQty =
                      int.tryParse(qtyController.text.trim()) ?? item.quantity;
                  final int quantity = parsedQty < 1 ? 1 : parsedQty;
                  final DateTime expiry = _parseDateOrFallback(
                    expiryController.text,
                    item.expiryDate,
                  );
                  final int freshness =
                      (int.tryParse(freshnessController.text.trim()) ??
                              item.freshnessScore)
                          .clamp(1, 5);
                  Navigator.of(dialogContext).pop(
                    _QuickEditResult(
                      nameController.text,
                      quantity,
                      expiry,
                      freshness,
                    ),
                  );
                },
                child: const Text('Save Changes'),
              ),
            ],
          );
        },
      ),
    );
    nameController.dispose();
    qtyController.dispose();
    expiryController.dispose();
    freshnessController.dispose();
    if (result == null) return;
    await _quickEditItem(
      item.id,
      result.name,
      result.quantity,
      newExpiryDate: result.expiryDate,
      newFreshnessScore: result.freshnessScore,
    );
    _showSnack('Item updated.');
  }

  Future<void> _openQuickEditPage(FoodItem item) async {
    final _QuickEditResult? result = await Navigator.of(context).push<_QuickEditResult>(
      MaterialPageRoute<_QuickEditResult>(
        builder: (BuildContext pageContext) => _ManualEditPage(item: item),
      ),
    );
    if (result == null) return;
    final String safeName = result.name.trim().isEmpty ? item.name : result.name.trim();
    final int safeQuantity = result.quantity < 1 ? 1 : result.quantity;
    final DateTime safeExpiryDate = DateUtils.dateOnly(result.expiryDate);
    final int safeFreshness = result.freshnessScore.clamp(1, 5);
    setState(() {
      item.name = safeName;
      item.quantity = safeQuantity;
      item.expiryDate = safeExpiryDate;
      item.freshnessScore = safeFreshness;
      _manualEditOverrides[item.id] = _QuickEditResult(
        safeName,
        safeQuantity,
        safeExpiryDate,
        safeFreshness,
      );
    });
    await _quickEditItem(
      item.id,
      safeName,
      safeQuantity,
      newExpiryDate: safeExpiryDate,
      newFreshnessScore: safeFreshness,
    );
    _showSnack('Item updated.');
  }

  Future<void> _markConsumed(String itemId) async {
    final int i = _inventory.indexWhere((FoodItem item) => item.id == itemId);
    if (i < 0 || _inventory[i].consumed) return;
    final FoodItem item = _inventory[i];
    setState(() {
      item.consumed = true;
      _stats.totalItemsSaved += item.quantity;
      _stats.co2eAvoidedKg += item.quantity * 0.35;
    });
    _emitUrgentActionAlert();
    if (_demoMode || _uid == null) return;
    try {
      final String uid = _uid!;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('inventory')
          .doc(itemId)
          .set(<String, dynamic>{
        'status': 'consumed',
      }, SetOptions(merge: true));
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        <String, dynamic>{
          'total_co2_saved': FieldValue.increment(item.quantity * 0.35),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      _showSnack('Mark consumed synced locally only.', isError: true);
    }
  }

  List<FoodItem> _sortedCandidatesForSuggestions() {
    final List<FoodItem> candidates =
        _inventory.where((FoodItem item) => !item.consumed).toList();
    candidates.sort((FoodItem a, FoodItem b) {
      final int aRisk = _isAtRisk(a) ? 0 : 1;
      final int bRisk = _isAtRisk(b) ? 0 : 1;
      if (aRisk != bRisk) return aRisk.compareTo(bRisk);
      final int dayCompare = _daysToExpiry(a).compareTo(_daysToExpiry(b));
      if (dayCompare != 0) return dayCompare;
      return a.freshnessScore.compareTo(b.freshnessScore);
    });
    return candidates;
  }

  List<String> _buildSuggestions() {
    if (!_demoMode && _liveSuggestions.length == 3) {
      return _liveSuggestions;
    }
    final List<FoodItem> candidates = _sortedCandidatesForSuggestions();
    if (candidates.isEmpty) {
      return <String>[
        'Run a new scan to refill inventory.',
        'Plan one quick meal for tonight.',
        'Track leftovers right after eating.',
      ];
    }
    final FoodItem first = candidates[0];
    final FoodItem second = candidates.length > 1 ? candidates[1] : first;
    final FoodItem third = candidates.length > 2 ? candidates[2] : second;
    return <String>[
      'Cook ${first.name} today.',
      'Use ${second.name} in a quick dish.',
      _isAtRisk(third)
          ? 'Save ${third.name} before tomorrow.'
          : 'Prep ${third.name} for tomorrow.',
    ];
  }

  List<FoodItem> _itemsForMarkConsumed() {
    final List<FoodItem> prioritized = _sortedCandidatesForSuggestions();
    if (prioritized.isEmpty) return <FoodItem>[];
    final List<FoodItem> atRisk =
        prioritized.where((FoodItem item) => _isAtRisk(item)).toList();
    if (atRisk.isNotEmpty) return atRisk;
    return prioritized.take(2).toList();
  }

  // -----------------------------------------------------------------------
  // Food emoji mapper — maps item name keywords to a relevant emoji.
  // -----------------------------------------------------------------------
  String _foodEmoji(String name) {
    final String lower = name.toLowerCase();
    const Map<String, String> emojiMap = <String, String>{
      'milk': '🥛', 'yogurt': '🥛', 'yoghurt': '🥛', 'cream': '🥛',
      'cheese': '🧀', 'butter': '🧈',
      'egg': '🥚', 'eggs': '🥚',
      'bread': '🍞', 'toast': '🍞', 'bun': '🍞', 'roll': '🍞',
      'rice': '🍚', 'noodle': '🍜', 'pasta': '🍝', 'spaghetti': '🍝',
      'chicken': '🍗', 'turkey': '🍗', 'wing': '🍗',
      'meat': '🥩', 'beef': '🥩', 'steak': '🥩', 'pork': '🥩', 'lamb': '🥩',
      'fish': '🐟', 'salmon': '🐟', 'tuna': '🐟', 'shrimp': '🦐', 'prawn': '🦐',
      'apple': '🍎', 'orange': '🍊', 'lemon': '🍋', 'lime': '🍋',
      'banana': '🍌', 'grape': '🍇', 'strawberry': '🍓', 'berry': '🍓',
      'blueberry': '🫐', 'watermelon': '🍉', 'melon': '🍈', 'peach': '🍑',
      'pear': '🍐', 'mango': '🥭', 'pineapple': '🍍', 'cherry': '🍒',
      'coconut': '🥥', 'kiwi': '🥝', 'avocado': '🥑',
      'tomato': '🍅', 'potato': '🥔', 'carrot': '🥕', 'corn': '🌽',
      'broccoli': '🥦', 'spinach': '🥬', 'lettuce': '🥬', 'salad': '🥗',
      'cabbage': '🥬', 'kale': '🥬', 'cucumber': '🥒', 'zucchini': '🥒',
      'pepper': '🌶️', 'chili': '🌶️', 'onion': '🧅', 'garlic': '🧄',
      'mushroom': '🍄', 'eggplant': '🍆', 'bean': '🫘', 'pea': '🫛',
      'cake': '🍰', 'pie': '🥧', 'cookie': '🍪', 'chocolate': '🍫',
      'ice cream': '🍦', 'donut': '🍩', 'candy': '🍬',
      'juice': '🧃', 'water': '💧', 'soda': '🥤', 'cola': '🥤',
      'coffee': '☕', 'tea': '🍵', 'beer': '🍺', 'wine': '🍷',
      'sauce': '🫙', 'ketchup': '🫙', 'mayo': '🫙', 'mustard': '🫙',
      'jam': '🫙', 'honey': '🍯', 'syrup': '🍯',
      'tofu': '🧊', 'soy': '🫘', 'soup': '🍲', 'stew': '🍲',
      'pizza': '🍕', 'burger': '🍔', 'hotdog': '🌭', 'sandwich': '🥪',
      'taco': '🌮', 'burrito': '🌯', 'sushi': '🍣',
      'dumpling': '🥟', 'dim sum': '🥟',
      'leftovers': '🍱', 'container': '🍱', 'tupperware': '🍱',
      'bottle': '🍼', 'can': '🥫', 'canned': '🥫',
    };
    for (final MapEntry<String, String> entry in emojiMap.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    // Fallback: generic food
    return '🍽️';
  }

  int get _atRiskCount => _inventory.where((FoodItem item) => _isAtRisk(item)).length;
  int get _availableCount =>
      _inventory.where((FoodItem item) => !item.consumed).length;
  int get _consumedCount =>
      _inventory.where((FoodItem item) => item.consumed).length;

  Future<bool> _ensureLiveModeReady() async {
    try {
      if (Firebase.apps.isEmpty) {
        throw Exception('Firebase is not initialized.');
      }
      User? user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) {
        throw Exception('Anonymous auth failed.');
      }
      _uid = user.uid;
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _liveStatusMessage = 'Live mode error: $error';
      });
      return false;
    }
  }

  void _subscribeToLiveInventory() {
    final String? uid = _uid;
    if (uid == null) return;
    _liveInventorySubscription?.cancel();
    _liveInventorySubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('inventory')
        .orderBy('estimated_expiry')
        .snapshots()
        .listen(
      (QuerySnapshot<Map<String, dynamic>> snapshot) {
        final List<FoodItem> items = snapshot.docs
            .asMap()
            .entries
            .map((MapEntry<int, QueryDocumentSnapshot<Map<String, dynamic>>> e) {
          return _foodItemFromDoc(e.value, e.key);
        }).toList();
        if (!mounted) return;
        setState(() {
          _inventory
            ..clear()
            ..addAll(items);
        });
        _emitUrgentActionAlert();
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _liveStatusMessage = 'Live inventory stream error: $error';
        });
      },
    );
  }

  FoodItem _foodItemFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    int index,
  ) {
    final Map<String, dynamic> data = doc.data();
    final int quantity = _toInt(data['quantity'], fallback: 1);
    final int freshness =
        _toInt(data['freshness_score'], fallback: 3).clamp(1, 5) as int;
    final Timestamp? expiryTs = data['estimated_expiry'] as Timestamp?;
    final int fallbackDays =
        _toInt(data['estimated_expiry_days'], fallback: freshness >= 4 ? 6 : 2);
    final DateTime expiryDate = expiryTs?.toDate() ??
        DateTime.now().add(
          Duration(days: fallbackDays.clamp(0, 30) as int),
        );
    final String status = (data['status'] as String?) ?? 'active';
    final String resolvedId = doc.id.isEmpty ? 'item_$index' : doc.id;
    final FoodItem item = FoodItem(
      id: doc.id.isEmpty ? 'item_$index' : doc.id,
      name: ((data['name'] as String?) ?? 'Unknown Item').trim(),
      quantity: quantity < 1 ? 1 : quantity,
      expiryDate: expiryDate,
      freshnessScore: freshness,
      consumed: status == 'consumed',
    );
    final _QuickEditResult? localEdit = _manualEditOverrides[resolvedId];
    if (localEdit != null && !item.consumed) {
      item
        ..name = localEdit.name.trim().isEmpty ? item.name : localEdit.name
        ..quantity = localEdit.quantity < 1 ? 1 : localEdit.quantity
        ..expiryDate = DateUtils.dateOnly(localEdit.expiryDate)
        ..freshnessScore = localEdit.freshnessScore.clamp(1, 5);
    }
    return item;
  }

  int _toInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  String _inventoryDocIdForName(String name, int index) {
    final String normalized =
        name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(
              RegExp(r'^_+|_+$'),
              '',
            );
    if (normalized.isEmpty) {
      return 'item_${DateTime.now().millisecondsSinceEpoch}_$index';
    }
    return '${normalized}_$index';
  }

  List<Map<String, dynamic>> _extractCallableItems(dynamic payload) {
    final dynamic data = payload is Map ? payload['items'] : null;
    if (data is! List) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> parsed = <Map<String, dynamic>>[];
    for (final dynamic raw in data) {
      if (raw is! Map) continue;
      final Map<String, dynamic> map = <String, dynamic>{};
      raw.forEach((Object? key, Object? value) {
        map['$key'] = value;
      });
      parsed.add(map);
    }
    return parsed;
  }

  Future<void> _upsertLiveInventory(
    String uid,
    List<Map<String, dynamic>> items,
  ) async {
    final WriteBatch batch = FirebaseFirestore.instance.batch();
    final CollectionReference<Map<String, dynamic>> ref = FirebaseFirestore
        .instance
        .collection('users')
        .doc(uid)
        .collection('inventory');
    final DateTime now = DateTime.now();
    for (int i = 0; i < items.length; i++) {
      final Map<String, dynamic> item = items[i];
      final String name = ((item['name'] as String?) ?? 'Unknown Item').trim();
      final int quantity = _toInt(item['quantity'], fallback: 1);
      final int days =
          _toInt(item['estimated_expiry_days'], fallback: 3).clamp(0, 30)
              as int;
      final int freshness =
          _toInt(item['freshness_score'], fallback: 3).clamp(1, 5) as int;
      final bool share = item['sharing_eligible'] == true;
      final DocumentReference<Map<String, dynamic>> docRef =
          ref.doc(_inventoryDocIdForName(name, i));
      batch.set(docRef, <String, dynamic>{
        'name': name.isEmpty ? 'Unknown Item' : name,
        'quantity': quantity < 1 ? 1 : quantity,
        'estimated_expiry': Timestamp.fromDate(now.add(Duration(days: days))),
        'status': 'active',
        'addedAt': FieldValue.serverTimestamp(),
        'sharing_eligible': share,
        'freshness_score': freshness,
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  Future<void> _loadLiveSuggestions() async {
    if (_demoMode || _uid == null) return;
    if (_geminiQuotaBlockedUntil != null &&
        DateTime.now().isBefore(_geminiQuotaBlockedUntil!)) {
      return;
    }
    if (_loadingLiveSuggestions) return;
    _loadingLiveSuggestions = true;
    final List<Map<String, dynamic>> items = _sortedCandidatesForSuggestions()
        .map((FoodItem item) => <String, dynamic>{
              'name': item.name,
              'quantity': item.quantity,
              'estimated_expiry_days': _daysToExpiry(item),
              'freshness_score': item.freshnessScore,
              'sharing_eligible': true,
            })
        .toList();
    if (items.isEmpty) {
      _loadingLiveSuggestions = false;
      if (!mounted) return;
      setState(() {
        _liveSuggestions = <String>[];
      });
      return;
    }
    try {
      // Call Gemini directly from Flutter (no Cloud Functions needed)
      final Map<String, dynamic> result =
          await GeminiService.instance.generateNudges(items: items);
      final dynamic actionsRaw = result['actions'];
      final List<String> live = <String>[];
      if (actionsRaw is List) {
        for (final dynamic action in actionsRaw) {
          if (action is Map) {
            final String title = ((action['title'] as String?) ?? '').trim();
            final String why = ((action['why'] as String?) ?? '').trim();
            final String merged = why.isEmpty ? title : '$title - $why';
            if (merged.isNotEmpty) live.add(merged);
          }
          if (live.length == 3) break;
        }
      }
      if (!mounted) return;
      setState(() {
        _liveSuggestions = live.length == 3 ? live : <String>[];
      });
    } catch (error) {
      _applyQuotaCooldownFromError(error.toString());
      if (!mounted) return;
      setState(() {
        _liveSuggestions = <String>[];
      });
    } finally {
      _loadingLiveSuggestions = false;
    }
  }

  Future<void> _goToSuggestions() async {
    if (_demoMode) {
      _setStep(DemoStep.suggestions);
      return;
    }
    _setStep(DemoStep.suggestions);
    unawaited(_loadLiveSuggestions());
  }

  Future<void> _startLiveProcessing() async {
    if (_processing) return;
    if (_geminiQuotaBlockedUntil != null &&
        DateTime.now().isBefore(_geminiQuotaBlockedUntil!)) {
      final int remaining = _quotaCooldownRemainingSeconds;
      final String msg =
          'Gemini free quota cooling down. Try again in ~${remaining}s.';
      if (mounted) {
        setState(() {
          _liveStatusMessage = msg;
          _step = DemoStep.scan;
        });
      }
      _showSnack(msg, isError: true);
      return;
    }
    final bool ready = await _ensureLiveModeReady();
    if (!ready) {
      if (!mounted) return;
      setState(() {
        _demoMode = true;
        _liveStatusMessage = null;
      });
      _showSnack('Live mode failed. Fallback to Demo Mode.', isError: true);
      return;
    }
    XFile? selected = _selectedImageFile;
    if (selected == null) {
      selected = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
      );
      if (selected == null) {
        _showSnack('Pick an image to run Live scan.', isError: true);
        return;
      }
      if (mounted) {
        setState(() {
          _selectedImageFile = selected;
          _selectedImageLabel = selected!.name;
        });
      }
    }
    if (_uid == null || !mounted) return;
    setState(() {
      _processing = true;
      _step = DemoStep.processing;
    });

    try {
      final String scanId = DateTime.now().millisecondsSinceEpoch.toString();
      final Reference ref = FirebaseStorage.instance
          .ref()
          .child('users/${_uid!}/scans/$scanId.jpg');
      final Uint8List bytes = await selected.readAsBytes();

      // Upload is optional for UX; do not block scan completion on slow network.
      unawaited(
        ref
            .putData(bytes, SettableMetadata(contentType: 'image/jpeg'))
            .catchError((Object uploadError) {
              debugPrint('Background scan upload failed: $uploadError');
            }),
      );

      final Map<String, dynamic> geminiResult = await GeminiService.instance
          .analyzeFridgeImage(imageBytes: bytes)
          .timeout(const Duration(seconds: 20));

      final List<Map<String, dynamic>> items = _extractCallableItems(geminiResult);
      if (items.isEmpty) {
        final String rawErrorMsg =
            (geminiResult['error'] as String?) ??
            'AI could not confidently detect items from this photo.';
        _applyQuotaCooldownFromError(rawErrorMsg);
        final String errorMsg = _friendlyErrorMessage(rawErrorMsg);
        if (!mounted) return;
        setState(() {
          _processing = false;
          _step = DemoStep.scan;
          _liveStatusMessage = errorMsg;
        });
        _showSnack(errorMsg, isError: true);
        return;
      }

      // Build inventory locally from AI result for instant UI — no Firestore wait.
      final DateTime now = DateTime.now();
      final List<FoodItem> localItems = <FoodItem>[];
      for (int i = 0; i < items.length; i++) {
        final Map<String, dynamic> item = items[i];
        String name =
            ((item['name'] as String?) ?? 'Unknown Item').trim();
        if (name.isEmpty) name = 'Unknown Item';
        final int quantity = _toInt(item['quantity'], fallback: 1).clamp(1, 99);
        final int days =
            _toInt(item['estimated_expiry_days'], fallback: 3).clamp(0, 30);
        final int freshness =
            _toInt(item['freshness_score'], fallback: 3).clamp(1, 5);

        // Use actual expiry_date from label if Gemini found one
        DateTime expiryDate;
        final String? expiryDateStr = item['expiry_date'] as String?;
        if (expiryDateStr != null && expiryDateStr.isNotEmpty) {
          final DateTime? parsed = DateTime.tryParse(expiryDateStr);
          expiryDate = parsed ?? now.add(Duration(days: days));
        } else {
          expiryDate = now.add(Duration(days: days));
        }

        localItems.add(FoodItem(
          id: _inventoryDocIdForName(name, i),
          name: name,
          quantity: quantity,
          expiryDate: expiryDate,
          freshnessScore: freshness,
        ));
      }
      // Sort by expiry soonest first
      localItems.sort((FoodItem a, FoodItem b) =>
          a.expiryDate.compareTo(b.expiryDate));

      if (!mounted) return;
      setState(() {
        _inventory
          ..clear()
          ..addAll(localItems);
        _lastScanImageBytes = bytes;
        _stats.totalScans += 1;
        _processing = false;
        _step = DemoStep.inventory;
      });
      _emitUrgentActionAlert(force: true);

      // Persist to Firestore + subscribe in background (non-blocking)
      unawaited(
        _upsertLiveInventory(_uid!, items).then((_) {
          _subscribeToLiveInventory();
        }).catchError((Object e) {
          debugPrint('Background Firestore sync failed: $e');
        }),
      );
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _step = DemoStep.scan;
      });
      _showSnack('Scan timed out. Try a smaller image or retry.', isError: true);
    } catch (error) {
      final String raw = 'Live scan failed: $error';
      _applyQuotaCooldownFromError(raw);
      final String message = _friendlyErrorMessage(raw);
      if (!mounted) return;
      setState(() {
        _processing = false;
        _step = DemoStep.scan;
        _liveStatusMessage = message;
      });
      _showSnack(message, isError: true);
    }
  }

  bool _isQuotaError(String message) {
    final String lower = message.toLowerCase();
    return lower.contains('quota exceeded') ||
        lower.contains('free_tier_requests') ||
        lower.contains('rate-limits') ||
        lower.contains('please retry in');
  }

  int _extractRetrySeconds(String message) {
    final RegExpMatch? match = RegExp(
      r'retry in\s+([0-9]+(?:\.[0-9]+)?)s',
      caseSensitive: false,
    ).firstMatch(message);
    if (match == null) return 60;
    final double? parsed = double.tryParse(match.group(1) ?? '');
    if (parsed == null) return 60;
    final int rounded = parsed.ceil();
    if (rounded < 10) return 10;
    if (rounded > 180) return 180;
    return rounded;
  }

  void _applyQuotaCooldownFromError(String message) {
    if (!_isQuotaError(message)) return;
    final int retrySeconds = _extractRetrySeconds(message);
    _geminiQuotaBlockedUntil = DateTime.now().add(Duration(seconds: retrySeconds));
    // Auto-clear the status message when cooldown expires
    _quotaCooldownTimer?.cancel();
    _quotaCooldownTimer = Timer(Duration(seconds: retrySeconds + 1), () {
      if (!mounted) return;
      setState(() {
        _liveStatusMessage = null;
        _geminiQuotaBlockedUntil = null;
      });
    });
  }

  int get _quotaCooldownRemainingSeconds {
    if (_geminiQuotaBlockedUntil == null) return 0;
    final int seconds =
        _geminiQuotaBlockedUntil!.difference(DateTime.now()).inSeconds;
    return seconds > 0 ? seconds : 0;
  }

  String _friendlyErrorMessage(String raw) {
    if (_isQuotaError(raw)) {
      final int retrySeconds = _quotaCooldownRemainingSeconds > 0
          ? _quotaCooldownRemainingSeconds
          : _extractRetrySeconds(raw);
      return 'Gemini free quota reached. Retry in ~${retrySeconds}s.';
    }
    return raw;
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  String _stepLabel(DemoStep step) {
    switch (step) {
      case DemoStep.home:
        return 'Home';
      case DemoStep.scan:
        return 'Scan';
      case DemoStep.processing:
        return 'Processing';
      case DemoStep.inventory:
        return 'Inventory';
      case DemoStep.suggestions:
        return 'Suggestions';
      case DemoStep.dashboard:
        return 'Dashboard';
    }
  }

  IconData _stepIcon(DemoStep step) {
    switch (step) {
      case DemoStep.home:
        return Icons.home_rounded;
      case DemoStep.scan:
        return Icons.camera_alt_rounded;
      case DemoStep.processing:
        return Icons.hourglass_top_rounded;
      case DemoStep.inventory:
        return Icons.kitchen_rounded;
      case DemoStep.suggestions:
        return Icons.lightbulb_rounded;
      case DemoStep.dashboard:
        return Icons.dashboard_rounded;
    }
  }

  Widget _buildDemoBadge() {
    final ThemeData theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Chip(
          avatar: Icon(
            Icons.bolt_rounded,
            size: 16,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          label: Text(
            'DEMO',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          backgroundColor: theme.colorScheme.primaryContainer,
          side: BorderSide(
            color: theme.colorScheme.outline.withOpacity(0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    final ThemeData theme = Theme.of(context);
    final List<DemoStep> steps = DemoStep.values;
    final int currentIndex = steps.indexOf(_step);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: List<Widget>.generate(steps.length, (int index) {
            final DemoStep step = steps[index];
            return FilterChip(
              selected: index == currentIndex,
              showCheckmark: false,
              onSelected: (_) => _setStep(step),
              selectedColor: theme.colorScheme.primaryContainer,
              backgroundColor: theme.colorScheme.surfaceContainerHigh,
              side: BorderSide(
                color: index == currentIndex
                    ? theme.colorScheme.primary.withOpacity(0.6)
                    : theme.colorScheme.outline.withOpacity(0.6),
              ),
              avatar: Icon(
                _stepIcon(step),
                size: 16,
                color: index == currentIndex
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
              label: Text(
                _stepLabel(step),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: index == currentIndex
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildShell({
    required String sectionTitle,
    required String sectionSubtitle,
    required Widget body,
    bool showSectionHeader = true,
  }) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        centerTitle: true,
        leading: const SizedBox.shrink(),
        leadingWidth: 88,
        title: const _BrandTitle(),
        actions: <Widget>[
          SizedBox(
            width: 88,
            child: _demoMode ? _buildDemoBadge() : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Container(color: theme.colorScheme.surface),
          ),
          Positioned(
            top: -170,
            left: -120,
            child: Container(
              width: 430,
              height: 430,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    Color(0x2E4FE5D4),
                    Color(0x0040E0D2),
                  ],
                  stops: <double>[0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            right: -190,
            bottom: -210,
            child: Container(
              width: 520,
              height: 520,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    Color(0x2E725CFF),
                    Color(0x003C55E8),
                  ],
                  stops: <double>[0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(color: const Color(0x7A070B12)),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildStepIndicator(),
                      if (showSectionHeader) ...<Widget>[
                        const SizedBox(height: 24),
                        Card(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  sectionTitle,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  sectionSubtitle,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Expanded(
                        child: body,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiCard({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              value,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontSize: 34,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKpiGrid() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 880;
        final bool medium = constraints.maxWidth >= 620 && constraints.maxWidth < 880;
        final double itemWidth;
        if (wide) {
          itemWidth = (constraints.maxWidth - 24) / 3;
        } else if (medium) {
          itemWidth = (constraints.maxWidth - 12) / 2;
        } else {
          itemWidth = constraints.maxWidth;
        }

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            SizedBox(
              width: itemWidth,
              child: _buildKpiCard(
                icon: Icons.qr_code_scanner_rounded,
                label: 'total_scans',
                value: _stats.totalScans.toString(),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _buildKpiCard(
                icon: Icons.savings_outlined,
                label: 'total_items_saved',
                value: _stats.totalItemsSaved.toString(),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: _buildKpiCard(
                icon: Icons.eco_outlined,
                label: 'co2e_avoided_kg',
                value: _stats.co2eAvoidedKg.toStringAsFixed(2),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _metaChip({required IconData icon, required String text}) {
    final ThemeData theme = Theme.of(context);
    return ActionChip(
      onPressed: () {},
      avatar: Icon(icon, size: 16, color: theme.colorScheme.primary),
      label: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.6)),
    );
  }

  Widget _miniInfoChip({
    required IconData icon,
    required String text,
    Color? color,
  }) {
    final ThemeData theme = Theme.of(context);
    final Color bg = color ?? theme.colorScheme.surfaceContainerHigh;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: theme.colorScheme.onSurface),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    const TextTheme appTextTheme = TextTheme(
      headlineMedium: TextStyle(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        height: 1.1,
        color: Color(0xFFF4F7FF),
      ),
      headlineSmall: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        height: 1.15,
        color: Color(0xFFF4F7FF),
      ),
      titleLarge: TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w800,
        color: Color(0xFFF4F7FF),
      ),
      titleMedium: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: Color(0xFFF4F7FF),
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: Color(0xFFBFC9D8),
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: Color(0xFFBFC9D8),
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Color(0xFFF4F7FF),
      ),
    );

    final ColorScheme seedScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4FE5D4),
      brightness: Brightness.dark,
    );
    final ColorScheme scheme = seedScheme.copyWith(
      background: const Color(0xFF070A10),
      onBackground: const Color(0xFFF4F7FF),
      surface: const Color(0xFF070A10),
      surfaceVariant: const Color(0xFF0F1725),
      surfaceContainer: const Color(0xFF0F1725),
      surfaceContainerHigh: const Color(0xFF121C2C),
      surfaceContainerHighest: const Color(0xFF162338),
      onSurface: const Color(0xFFF4F7FF),
      onSurfaceVariant: const Color(0xFFBFC9D8),
      primary: const Color(0xFF3FE0D0),
      onPrimary: const Color(0xFF06211E),
      primaryContainer: const Color(0xFF0B3A35),
      onPrimaryContainer: const Color(0xFFBFF7F0),
      secondaryContainer: const Color(0xFF1D2A3D),
      onSecondaryContainer: const Color(0xFFE7F0F8),
      outline: const Color(0xFF2A3A4D),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF070A10),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF070A10),
        foregroundColor: const Color(0xFFF4F7FF),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: appTextTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: const Color(0xFFF4F7FF),
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outline.withOpacity(0.45)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      textTheme: appTextTheme,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      title: 'FridgeGuardian Demo',
      theme: _buildTheme(Brightness.dark),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: _buildCurrentScreen(),
    );
  }

  Widget _buildCurrentScreen() {
    switch (_step) {
      case DemoStep.home:
        return _buildHomeScreen();
      case DemoStep.scan:
        return _buildScanScreen();
      case DemoStep.processing:
        return _buildProcessingScreen();
      case DemoStep.inventory:
        return _buildInventoryScreenStable();
      case DemoStep.suggestions:
        return _buildSuggestionsScreen();
      case DemoStep.dashboard:
        return _buildDashboardScreen();
    }
  }

  Widget _buildHomeScreen() {
    final ThemeData theme = Theme.of(context);
    final List<FoodItem> urgentItems = _urgentRedItems();
    return _buildShell(
      sectionTitle: 'Smart Food Management',
      sectionSubtitle: 'Scan your fridge, prioritize expiring items, reduce waste.',
      showSectionHeader: false,
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              children: <Widget>[
                if (urgentItems.isNotEmpty) ...<Widget>[
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                Icons.notification_important_rounded,
                                color: theme.colorScheme.onErrorContainer,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Urgent Action Dashboard',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: theme.colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Red items need action now:',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...urgentItems.take(4).map((FoodItem item) {
                            final int days = _daysToExpiry(item);
                            final String urgency = days <= 0
                                ? 'today'
                                : 'in $days day(s)';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    Icons.circle,
                                    size: 8,
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${item.name} • Qty ${item.quantity} • Expires $urgency',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onErrorContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 8),
                          FilledButton.tonalIcon(
                            onPressed: () => _setStep(DemoStep.inventory),
                            icon: const Icon(Icons.warning_amber_rounded),
                            label: const Text('Review Urgent Items'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Smart Food Management',
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Scan your fridge, prioritize expiring items, reduce waste.',
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            _metaChip(icon: Icons.flag_rounded, text: 'SDG 12.3'),
                            _metaChip(icon: Icons.public_rounded, text: 'SDG 13'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Card(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: SwitchListTile(
                    title: Text(
                      'Demo Mode',
                      style: theme.textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      'Run a fully offline demo with simulated scanning and local state.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    value: _demoMode,
                    onChanged: _toggleDemoMode,
                  ),
                ),
                const SizedBox(height: 12),
                _buildFcmConnectionIndicator(),
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.tonalIcon(
                      onPressed: _simulateUrgentPushPreview,
                      icon: const Icon(Icons.notification_important_rounded),
                      label: const Text('Test Urgent Alert'),
                    ),
                  ),
                ),
                if (_liveStatusMessage != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              _liveStatusMessage!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close, size: 18, color: theme.colorScheme.onErrorContainer),
                            onPressed: () => setState(() => _liveStatusMessage = null),
                            tooltip: 'Dismiss',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                _buildKpiGrid(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: () => _setStep(DemoStep.scan),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Start Demo Flow'),
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildScanScreen() {
    final ThemeData theme = Theme.of(context);
    final bool liveMode = !_demoMode;
    return _buildShell(
      sectionTitle: 'Scan',
      sectionSubtitle: liveMode
          ? 'Pick your fridge image, then run live AI scan.'
          : 'Run offline demo scan with simulated results.',
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              children: <Widget>[
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    height: 300,
                    padding: _lastScanImageBytes != null
                        ? EdgeInsets.zero
                        : const EdgeInsets.all(24),
                    child: _lastScanImageBytes != null
                        ? Image.memory(
                            _lastScanImageBytes!,
                            width: double.infinity,
                            height: 300,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                Icons.photo_camera_rounded,
                                size: 64,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Camera Placeholder',
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _selectedImageLabel == null
                                    ? 'No image selected'
                                    : 'Selected: $_selectedImageLabel',
                                style: theme.textTheme.bodyLarge,
                              ),
                            ],
                          ),
                  ),
                ),
                if (liveMode) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'Live Mode is active. Pick an image and run scan.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (liveMode) ...<Widget>[
            FilledButton.tonal(
              onPressed: _pickImage,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.photo_library_outlined),
                  SizedBox(width: 8),
                  Text('Pick Image'),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: liveMode ? _startLiveProcessing : _startDemoProcessing,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text(liveMode
                ? 'Scan Whole Fridge (Live AI)'
                : 'Scan Whole Fridge (Demo)'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _goBackStep,
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('Back'),
          ),
        ],
      ),
    );
  }
  Widget _buildProcessingScreen() {
    final ThemeData theme = Theme.of(context);
    return _buildShell(
      sectionTitle: 'Processing',
      sectionSubtitle: 'We are identifying items from your fridge snapshot.',
      body: Center(
        child: Card(
                  color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 16),
                Text(
                  'Analyzing fridge contents...',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  _demoMode
                      ? 'Demo will complete shortly.'
                      : 'Live scan may take up to ~20 seconds for detailed analysis.',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildInventoryScreen() {
    return _buildInventoryScreenCrashSafe();
    final ThemeData theme = Theme.of(context);
    final List<FoodItem> visible =
        _inventory.where((FoodItem i) => !i.consumed).toList();
    final List<FoodItem> atRisk = visible.where(_isAtRisk).toList();
    final String bannerText = atRisk.isNotEmpty
        ? '${atRisk.length} items at risk - use these today'
        : 'No urgent items right now';

    return _buildShell(
      sectionTitle: 'Inventory',
      sectionSubtitle: 'Review scanned food and fix risk items quickly.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Card(
            color: atRisk.isNotEmpty
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Icon(
                    atRisk.isNotEmpty
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_rounded,
                    color: atRisk.isNotEmpty
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Risk Summary: $bannerText',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: atRisk.isNotEmpty
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (visible.isEmpty)
            Expanded(
              child: Card(
                color: theme.colorScheme.surfaceContainerHigh,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 56,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'No visible items in inventory',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => _setStep(DemoStep.scan),
                          icon: const Icon(Icons.camera_alt_rounded),
                          label: const Text('Run Scan'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: visible.length,
                separatorBuilder: (_, __) => const SizedBox(height: 14),
                itemBuilder: (BuildContext context, int index) {
                  final FoodItem item = visible[index];
                  final int days = _daysToExpiry(item);
                  final bool risk = _isAtRisk(item);
                  final bool soon = !risk && !item.consumed && days <= 4;
                  final IconData leadingIcon = item.consumed
                      ? Icons.done_all_rounded
                      : risk
                          ? Icons.warning_amber_rounded
                          : soon
                              ? Icons.schedule_rounded
                              : Icons.check_circle_rounded;
                  final Color stripeColor = item.consumed
                      ? theme.colorScheme.outline
                      : risk
                          ? theme.colorScheme.error
                          : soon
                              ? theme.colorScheme.tertiary
                              : theme.colorScheme.primaryContainer;
                  final Color iconColor = item.consumed
                      ? theme.colorScheme.onSurfaceVariant
                      : risk
                          ? theme.colorScheme.error
                          : soon
                              ? theme.colorScheme.tertiary
                              : theme.colorScheme.primary;
                  return Card(
                    color: theme.colorScheme.surfaceContainerHigh,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: theme.colorScheme.outline.withOpacity(0.6),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 7,
                          decoration: BoxDecoration(
                            color: stripeColor,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Icon(
                                      leadingIcon,
                                      color: iconColor,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        item.name,
                                        style: theme.textTheme.titleMedium?.copyWith(
                                          color: theme.colorScheme.onSurface,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Quick Edit',
                                      onPressed: item.consumed
                                          ? null
                                          : () => _openQuickEditPage(item),
                                      icon: Icon(
                                        Icons.edit_rounded,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Expires in $days day(s)',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: risk
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Qty ${item.quantity} • Freshness ${item.freshnessScore}/5'
                                  '${item.consumed ? ' • Consumed' : ''}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (risk) ...<Widget>[
                                  const SizedBox(height: 10),
                                  Chip(
                                    avatar: Icon(
                                      Icons.priority_high_rounded,
                                      size: 16,
                                      color: theme.colorScheme.onErrorContainer,
                                    ),
                                    label: Text(
                                      'AT RISK',
                                      style: TextStyle(
                                        color: theme.colorScheme.onErrorContainer,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    backgroundColor: theme.colorScheme.errorContainer,
                                    side: BorderSide(
                                      color: theme.colorScheme.error.withOpacity(0.45),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: visible.isEmpty ? null : _goToSuggestions,
            icon: const Icon(Icons.lightbulb_rounded),
            label: const Text('Continue to Suggestions'),
          ),
        ],
      ),
    );
  }
  Widget _buildInventoryScreenStable() {
    final ThemeData theme = Theme.of(context);
    final TextTheme t = theme.textTheme;
    final TextStyle titleStyle = t.titleMedium ??
        const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
        );
    final TextStyle bodyStyle = t.bodyMedium ??
        const TextStyle(
          fontSize: 14,
        );
    final TextStyle subStyle = t.bodySmall ??
        const TextStyle(
          fontSize: 12,
          color: Colors.grey,
        );
    final List<FoodItem> visible =
        _inventory.where((FoodItem i) => !i.consumed).toList();
    final List<FoodItem> atRisk = visible.where(_isAtRisk).toList();
    final String bannerText = atRisk.isNotEmpty
        ? '${atRisk.length} items at risk - use these today'
        : 'No urgent items right now';

    return _buildShell(
      sectionTitle: 'Inventory',
      sectionSubtitle: 'Review scanned food and fix risk items quickly.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Card(
            color: atRisk.isNotEmpty
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Icon(
                    atRisk.isNotEmpty
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_rounded,
                    color: atRisk.isNotEmpty
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Risk Summary: $bannerText',
                      style: titleStyle.copyWith(
                        color: atRisk.isNotEmpty
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (visible.isEmpty)
            Expanded(
              child: Card(
                color: theme.colorScheme.surfaceContainerHigh,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 56,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'No visible items in inventory',
                          style: titleStyle.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => _setStep(DemoStep.scan),
                          icon: const Icon(Icons.camera_alt_rounded),
                          label: const Text('Run Scan'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: visible.length,
                separatorBuilder: (_, __) => const SizedBox(height: 14),
                itemBuilder: (BuildContext context, int index) {
                  final FoodItem item = visible[index];
                  final int days = _daysToExpiry(item);
                  final bool risk = _isAtRisk(item);
                  final bool soon = !risk && days <= 4;
                  final IconData leadingIcon = risk
                      ? Icons.warning_amber_rounded
                      : soon
                          ? Icons.schedule_rounded
                          : Icons.check_circle_rounded;
                  final Color stripeColor = risk
                      ? theme.colorScheme.error
                      : soon
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.primaryContainer;
                  final Color iconColor = risk
                      ? theme.colorScheme.error
                      : soon
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.primary;

                  return Card(
                    key: ValueKey<String>('inv_${item.id}_$index'),
                    color: theme.colorScheme.surfaceContainerHigh,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: theme.colorScheme.outline.withOpacity(0.6),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 7,
                          decoration: BoxDecoration(
                            color: stripeColor,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Icon(
                                      leadingIcon,
                                      color: iconColor,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        item.name,
                                        style: titleStyle.copyWith(
                                          color: theme.colorScheme.onSurface,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Quick Edit',
                                      onPressed: () => _openQuickEditPage(item),
                                      icon: Icon(
                                        Icons.edit_rounded,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Expiry: ${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                                  style: titleStyle.copyWith(
                                    color: risk
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  risk
                                      ? 'Consume TODAY — at risk!'
                                      : soon
                                          ? 'Consume within $days day(s)'
                                          : 'Consume by ${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                                  style: bodyStyle.copyWith(
                                    color: risk
                                        ? theme.colorScheme.error
                                        : soon
                                            ? theme.colorScheme.tertiary
                                            : theme.colorScheme.onSurfaceVariant,
                                    fontWeight: risk || soon
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Qty ${item.quantity} • Freshness ${item.freshnessScore}/5',
                                  style: bodyStyle.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (risk) ...<Widget>[
                                  const SizedBox(height: 10),
                                  Chip(
                                    avatar: Icon(
                                      Icons.priority_high_rounded,
                                      size: 16,
                                      color: theme.colorScheme.onErrorContainer,
                                    ),
                                    label: Text(
                                      'AT RISK',
                                      style: TextStyle(
                                        color: theme.colorScheme.onErrorContainer,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    backgroundColor: theme.colorScheme.errorContainer,
                                    side: BorderSide(
                                      color: theme.colorScheme.error.withOpacity(0.45),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: visible.isEmpty ? null : _goToSuggestions,
            icon: const Icon(Icons.lightbulb_rounded),
            label: const Text('Continue to Suggestions'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _goBackStep,
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryScreenStableV2() {
    final ThemeData theme = Theme.of(context);
    final TextTheme t = theme.textTheme;
    final TextStyle titleStyle = t.titleMedium ??
        const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
        );
    final TextStyle bodyStyle = t.bodyMedium ??
        const TextStyle(
          fontSize: 14,
        );
    final TextStyle subStyle = t.bodySmall ??
        const TextStyle(
          fontSize: 12,
          color: Colors.grey,
        );

    final List<FoodItem> visible =
        _inventory.where((FoodItem i) => !i.consumed).toList();
    final List<FoodItem> atRisk = visible.where(_isAtRisk).toList();
    final String bannerText = atRisk.isNotEmpty
        ? '${atRisk.length} items at risk - use these today'
        : 'No urgent items right now';

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        centerTitle: true,
        leading: const SizedBox.shrink(),
        leadingWidth: 88,
        title: const _BrandTitle(),
        actions: <Widget>[
          SizedBox(
            width: 88,
            child: _demoMode ? _buildDemoBadge() : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Container(color: theme.colorScheme.surface),
          ),
          Positioned(
            top: -170,
            left: -120,
            child: Container(
              width: 430,
              height: 430,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    Color(0x2E4FE5D4),
                    Color(0x0040E0D2),
                  ],
                  stops: <double>[0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            right: -190,
            bottom: -210,
            child: Container(
              width: 520,
              height: 520,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    Color(0x2E725CFF),
                    Color(0x003C55E8),
                  ],
                  stops: <double>[0.0, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(color: const Color(0x7A070B12)),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildStepIndicator(),
                      const SizedBox(height: 24),
                      Expanded(
                        child: CustomScrollView(
                          slivers: <Widget>[
                            SliverToBoxAdapter(
                              child: Card(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'Inventory',
                                        style: titleStyle.copyWith(
                                          color: theme.colorScheme.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Review scanned food and fix risk items quickly.',
                                        style: bodyStyle.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SliverToBoxAdapter(child: SizedBox(height: 12)),
                            SliverToBoxAdapter(
                              child: Card(
                                color: atRisk.isNotEmpty
                                    ? theme.colorScheme.errorContainer
                                    : theme.colorScheme.tertiaryContainer,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    children: <Widget>[
                                      Icon(
                                        Icons.warning_amber_rounded,
                                        color: atRisk.isNotEmpty
                                            ? theme.colorScheme.onErrorContainer
                                            : theme.colorScheme.onTertiaryContainer,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Risk Summary: $bannerText',
                                          style: titleStyle.copyWith(
                                            color: atRisk.isNotEmpty
                                                ? theme.colorScheme.onErrorContainer
                                                : theme.colorScheme.onTertiaryContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SliverToBoxAdapter(child: SizedBox(height: 12)),
                            if (visible.isEmpty)
                              SliverToBoxAdapter(
                                child: Card(
                                  color: theme.colorScheme.surfaceContainerHigh,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          Icon(
                                            Icons.inventory_2_outlined,
                                            size: 56,
                                            color: theme.colorScheme.primary,
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            'No visible items in inventory',
                                            style: titleStyle.copyWith(
                                              color: theme.colorScheme.onSurface,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          FilledButton.icon(
                                            onPressed: () => _setStep(DemoStep.scan),
                                            icon: const Icon(Icons.camera_alt_rounded),
                                            label: const Text('Run Scan'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (BuildContext context, int index) {
                                    if (index < 0 || index >= visible.length) {
                                      return const SizedBox.shrink();
                                    }
                                    final FoodItem item = visible[index];
                                    return KeyedSubtree(
                                      key: ValueKey<String>('inv_${item.id}_$index'),
                                      child: _buildInventoryItemCardStable(item),
                                    );
                                  },
                                  childCount: visible.length,
                                ),
                              ),
                            const SliverPadding(
                              padding: EdgeInsets.only(bottom: 24),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: visible.isEmpty ? null : _goToSuggestions,
            icon: const Icon(Icons.lightbulb_rounded),
            label: const Text('Continue to Suggestions'),
          ),
        ),
      ),
    );
  }

  Widget _buildInventoryItemCardStable(FoodItem item) {
    final ThemeData theme = Theme.of(context);
    final TextTheme t = theme.textTheme;
    final TextStyle titleStyle = t.titleMedium ??
        const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
        );
    final TextStyle bodyStyle = t.bodyMedium ??
        const TextStyle(
          fontSize: 14,
        );
    final TextStyle subStyle = t.bodySmall ??
        const TextStyle(
          fontSize: 12,
        );

    final int days = _daysToExpiry(item);
    final bool risk = _isAtRisk(item);
    final bool soon = !risk && days <= 4;
    final IconData leadingIcon = risk
        ? Icons.warning_amber_rounded
        : soon
            ? Icons.schedule_rounded
            : Icons.check_circle_rounded;
    final Color stripeColor = risk
        ? theme.colorScheme.error
        : soon
            ? theme.colorScheme.tertiary
            : theme.colorScheme.primaryContainer;
    final Color iconColor = risk
        ? theme.colorScheme.error
        : soon
            ? theme.colorScheme.tertiary
            : theme.colorScheme.primary;

    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outline.withOpacity(0.6),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            width: 7,
            decoration: BoxDecoration(
              color: stripeColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                bottomLeft: Radius.circular(16),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // ---- Left: item details ----
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              leadingIcon,
                              color: iconColor,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.name,
                                style: titleStyle.copyWith(
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Quick Edit',
                              onPressed: () => _openQuickEditPage(item),
                              icon: Icon(
                                Icons.edit_rounded,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                  Text(
                    'Expiry: ${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                    style: titleStyle.copyWith(
                      color: risk
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    risk
                        ? 'Consume TODAY — at risk!'
                        : soon
                            ? 'Consume within $days day(s)'
                            : 'Consume by ${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                    style: bodyStyle.copyWith(
                      color: risk
                          ? theme.colorScheme.error
                          : soon
                              ? theme.colorScheme.tertiary
                              : theme.colorScheme.onSurfaceVariant,
                      fontWeight: risk || soon
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Qty ${item.quantity} • Freshness ${item.freshnessScore}/5',
                    style: bodyStyle.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                        if (risk) ...<Widget>[
                          const SizedBox(height: 10),
                          Chip(
                            avatar: Icon(
                              Icons.priority_high_rounded,
                              size: 16,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            label: Text(
                              'AT RISK',
                              style: subStyle.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            backgroundColor: theme.colorScheme.errorContainer,
                            side: BorderSide(
                              color: theme.colorScheme.error.withOpacity(0.45),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // ---- Right: fridge photo thumbnail ----
                  const SizedBox(width: 12),
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: risk
                          ? theme.colorScheme.errorContainer.withOpacity(0.5)
                          : soon
                              ? theme.colorScheme.tertiaryContainer.withOpacity(0.5)
                              : theme.colorScheme.primaryContainer.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: (risk
                                ? theme.colorScheme.error
                                : soon
                                    ? theme.colorScheme.tertiary
                                    : theme.colorScheme.primary)
                            .withOpacity(0.35),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    alignment: Alignment.center,
                    child: _lastScanImageBytes != null
                        ? Image.memory(
                            _lastScanImageBytes!,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : Text(
                            _foodEmoji(item.name),
                            style: const TextStyle(fontSize: 28),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryScreenCrashSafe() {
    final visible = _inventory.where((i) => !i.consumed).toList();
    final atRisk = visible.where(_isAtRisk).toList();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final t = theme.textTheme;
    final titleStyle = t.titleMedium ??
        const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
        );
    final bodyStyle = t.bodyMedium ??
        const TextStyle(
          fontSize: 14,
        );
    final subStyle = (t.bodySmall ??
            const TextStyle(
              fontSize: 12,
            ))
        .copyWith(color: colorScheme.onSurfaceVariant);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Inventory', style: titleStyle),
                      const SizedBox(height: 6),
                      Text(
                        'Review scanned food and fix risk items quickly.',
                        style: bodyStyle.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Risk Summary: ${atRisk.length} items at risk - use these today',
                          style: bodyStyle.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('No inventory items yet', style: titleStyle),
                        const SizedBox(height: 8),
                        Text(
                          'Run a demo scan to add items.',
                          style: bodyStyle.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index < 0 || index >= visible.length) {
                    return const SizedBox.shrink();
                  }
                  final item = visible[index];
                  return KeyedSubtree(
                    key: ValueKey('inv_${item.id}_$index'),
                    child: _buildInventoryItemCardCrashSafe(item),
                  );
                },
                childCount: visible.length,
              ),
            ),
          const SliverPadding(
            padding: EdgeInsets.only(bottom: 24),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: visible.isEmpty ? null : _goToSuggestions,
            icon: const Icon(Icons.lightbulb_outline),
            label: const Text('Continue to Suggestions'),
          ),
        ),
      ),
    );
  }

  Widget _buildInventoryItemCardCrashSafe(FoodItem item) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final t = theme.textTheme;
    final titleStyle = t.titleMedium ??
        const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
        );
    final bodyStyle = t.bodyMedium ??
        const TextStyle(
          fontSize: 14,
        );
    final subStyle = (t.bodySmall ??
            const TextStyle(
              fontSize: 12,
            ))
        .copyWith(color: colorScheme.onSurfaceVariant);
    final days = _daysToExpiry(item);
    final atRisk = _isAtRisk(item);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              atRisk ? Icons.warning_amber_rounded : Icons.check_circle_outline,
              color: atRisk ? colorScheme.error : colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(item.name, style: titleStyle),
                      ),
                      if (atRisk)
                        Chip(
                          label: Text(
                            'AT RISK',
                            style: subStyle.copyWith(
                              color: colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          backgroundColor: colorScheme.errorContainer,
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Expiry: ${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                    style: bodyStyle.copyWith(
                      color: atRisk ? colorScheme.error : colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    atRisk
                        ? 'Consume TODAY — at risk!'
                        : days <= 4
                            ? 'Consume within $days day(s)'
                            : 'Consume by ${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                    style: subStyle.copyWith(
                      color: atRisk
                          ? colorScheme.error
                          : days <= 4
                              ? colorScheme.tertiary
                              : colorScheme.onSurfaceVariant,
                      fontWeight: atRisk || days <= 4
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Qty: ${item.quantity}   Freshness: ${item.freshnessScore}/5',
                    style: subStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionsScreen() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<String> suggestions = _buildSuggestions();
    final List<FoodItem> markTargets = _itemsForMarkConsumed();
    final List<IconData> suggestionIcons = <IconData>[
      Icons.restaurant_menu_rounded,
      Icons.bolt_rounded,
      Icons.schedule_rounded,
    ];

    return _buildShell(
      sectionTitle: 'Suggestions',
      sectionSubtitle: 'Top actions prioritized by expiring soon items.',
      body: Container(
        color: scheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.lightbulb_rounded, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Top 3 actions',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Prioritized by expiring soon',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...List<Widget>.generate(suggestions.length, (int index) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Card(
                        color: scheme.surfaceContainerHigh,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: scheme.primaryContainer,
                            child: Icon(
                              suggestionIcons[index],
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                          title: Text(
                            '${index + 1}. ${suggestions[index]}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '~15 min',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                  Text(
                    'Mark Consumed',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (markTargets.isEmpty)
                    Card(
                      color: scheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'No available items to consume.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    ...markTargets.map((FoodItem item) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Card(
                          color: scheme.surfaceContainerHigh,
                          child: ListTile(
                            title: Text(
                              item.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              'Qty ${item.quantity} | Freshness ${item.freshnessScore}/5',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: SizedBox(
                              width: 140,
                              child: FilledButton.tonal(
                                onPressed: item.consumed
                                    ? null
                                    : () => _markConsumed(item.id),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    item.consumed ? 'Consumed' : 'Mark Consumed',
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _setStep(DemoStep.inventory),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _setStep(DemoStep.dashboard),
                    icon: const Icon(Icons.dashboard_rounded),
                    label: const Text('Open Dashboard'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildDashboardScreen() {
    final ThemeData theme = Theme.of(context);
    return _buildShell(
      sectionTitle: 'Dashboard',
      sectionSubtitle: 'Track scan volume, food saved, and sustainability impact.',
      body: ListView(
        children: <Widget>[
          _buildKpiGrid(),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.insights_rounded, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Impact Summary',
                        style: theme.textTheme.titleLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _miniInfoChip(
                        icon: Icons.inventory_2_rounded,
                        text: 'available_items: $_availableCount',
                      ),
                      _miniInfoChip(
                        icon: Icons.task_alt_rounded,
                        text: 'consumed_items: $_consumedCount',
                      ),
                      _miniInfoChip(
                        icon: Icons.warning_amber_rounded,
                        text: 'at_risk_items: $_atRiskCount',
                        color: const Color(0xFF4C2C1E),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _setStep(DemoStep.scan),
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Run Another Demo Scan'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _setStep(DemoStep.home),
            icon: const Icon(Icons.home_rounded),
            label: const Text('Back to Home'),
          ),
        ],
      ),
    );
  }
}

class _QuickEditResult {
  const _QuickEditResult(
    this.name,
    this.quantity,
    this.expiryDate,
    this.freshnessScore,
  );
  final String name;
  final int quantity;
  final DateTime expiryDate;
  final int freshnessScore;
}

class _ManualEditPage extends StatefulWidget {
  const _ManualEditPage({required this.item});

  final FoodItem item;

  @override
  State<_ManualEditPage> createState() => _ManualEditPageState();
}

class _ManualEditPageState extends State<_ManualEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _qtyController;
  late final TextEditingController _expiryController;
  late final TextEditingController _freshnessController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.name);
    _qtyController = TextEditingController(text: widget.item.quantity.toString());
    _expiryController = TextEditingController(
      text: _formatDateDmy(widget.item.expiryDate),
    );
    _freshnessController = TextEditingController(
      text: widget.item.freshnessScore.toString(),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _qtyController.dispose();
    _expiryController.dispose();
    _freshnessController.dispose();
    super.dispose();
  }

  DateTime _parseDateOrFallback(String input, DateTime fallback) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) return DateUtils.dateOnly(fallback);

    final DateTime? direct = DateTime.tryParse(trimmed);
    if (direct != null) return DateUtils.dateOnly(direct);

    final RegExpMatch? dmy =
        RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(trimmed);
    if (dmy != null) {
      final int day = int.tryParse(dmy.group(1) ?? '') ?? 0;
      final int month = int.tryParse(dmy.group(2) ?? '') ?? 0;
      final int year = int.tryParse(dmy.group(3) ?? '') ?? 0;
      if (year >= 2000 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        final DateTime parsed = DateTime(year, month, day);
        if (parsed.year == year && parsed.month == month && parsed.day == day) {
          return DateUtils.dateOnly(parsed);
        }
      }
    }
    return DateUtils.dateOnly(fallback);
  }

  String _formatDateDmy(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  void _save() {
    final int parsedQty =
        int.tryParse(_qtyController.text.trim()) ?? widget.item.quantity;
    final int quantity = parsedQty < 1 ? 1 : parsedQty;
    final DateTime expiry = _parseDateOrFallback(
      _expiryController.text,
      widget.item.expiryDate,
    );
    final int freshness =
        (int.tryParse(_freshnessController.text.trim()) ??
                widget.item.freshnessScore)
            .clamp(1, 5);
    Navigator.of(context).pop(
      _QuickEditResult(
        _nameController.text,
        quantity,
        expiry,
        freshness,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manual Edit Item'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  children: <Widget>[
                    TextField(
                      controller: _nameController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _qtyController,
                      textInputAction: TextInputAction.next,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Quantity'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _expiryController,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Expiry Date (DD/MM/YYYY)',
                        suffixIcon: IconButton(
                          tooltip: 'Pick Date',
                          icon: const Icon(Icons.calendar_today_rounded),
                          onPressed: () async {
                            final DateTime initial = _parseDateOrFallback(
                              _expiryController.text,
                              widget.item.expiryDate,
                            );
                            final DateTime? picked = await showDatePicker(
                              context: context,
                              initialDate: initial,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (picked == null) return;
                            setState(() {
                              _expiryController.text = _formatDateDmy(picked);
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _freshnessController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Freshness (1-5)',
                        helperText: '1 = poor, 5 = excellent',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('Save Changes'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            scheme.primary,
            scheme.tertiary,
            scheme.secondary,
          ],
        ).createShader(bounds);
      },
      child: Text(
        'FridgeGuardian',
        style: theme.textTheme.titleLarge?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
