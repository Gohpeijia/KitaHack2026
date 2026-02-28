import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../service/gemini_service.dart';
import 'auth_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  bool _isAuthenticated = false;
  bool _demoMode = true;
  bool _processing = false;
  DemoStep _step = DemoStep.home;
  String? _selectedImageLabel;
  XFile? _selectedImageFile;
  String? _uid;
  String? _liveStatusMessage;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _liveInventorySubscription;
  List<String> _liveSuggestions = <String>[];
  bool _loadingLiveSuggestions = false;
    DateTime? _geminiQuotaBlockedUntil;
  final DemoStats _stats = DemoStats();
  final List<FoodItem> _inventory = <FoodItem>[];
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<RemoteMessage>? _onMessageSubscription;
  StreamSubscription<RemoteMessage>? _onMessageOpenedSubscription;
  StreamSubscription<String>? _onTokenRefreshSubscription;
  bool _notificationReady = false;
  bool _localNotifAvailable = false;
  DateTime? _lastExpiryNotifCheck;
  final Set<int> _scheduledNotifIds = <int>{};

  static const AndroidNotificationChannel _reminderChannel =
      AndroidNotificationChannel(
    'expiry_reminders',
    'Expiry Reminders',
    description: 'Alerts for items close to expiry.',
    importance: Importance.high,
  );

  @override
  void initState() {
    super.initState();
    // Check if a user is already signed in from a previous session.
    final User? existing = FirebaseAuth.instance.currentUser;
    if (existing != null) {
      _isAuthenticated = true;
      _uid = existing.uid;
    }
    unawaited(_initializeNotifications());
  }

  @override
  void dispose() {
    _liveInventorySubscription?.cancel();
    _onMessageSubscription?.cancel();
    _onMessageOpenedSubscription?.cancel();
    _onTokenRefreshSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeNotifications() async {
    if (_notificationReady) return;

    // ── Phase 1: Timezone setup (needed by both local + scheduled) ──────
    try {
      tz.initializeTimeZones();
      try {
        final String tzName =
            (await FlutterTimezone.getLocalTimezone()).toString();
        tz.setLocalLocation(tz.getLocation(tzName));
      } catch (_) {
        tz.setLocalLocation(tz.getLocation('UTC'));
      }
    } catch (_) {
      // Timezone init failure is non-fatal
    }

    // ── Phase 2: Local notifications (mobile/desktop native only) ───────
    // flutter_local_notifications does NOT support Web, so skip on web.
    if (!kIsWeb) {
      try {
        final AndroidInitializationSettings androidSettings =
            const AndroidInitializationSettings('@mipmap/ic_launcher');
        const DarwinInitializationSettings iosSettings =
            DarwinInitializationSettings();
        final InitializationSettings settings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );
        await _localNotifications.initialize(settings);

        final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
            _localNotifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(_reminderChannel);
        await androidPlugin?.requestNotificationsPermission();

        final IOSFlutterLocalNotificationsPlugin? iosPlugin =
            _localNotifications.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
        await iosPlugin?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        _localNotifAvailable = true;
      } catch (e) {
        debugPrint('Local notifications init failed: $e');
        _localNotifAvailable = false;
      }
    }

    // ── Phase 3: Firebase Cloud Messaging (works on Web + mobile) ───────
    try {
      await _messaging.requestPermission(
          alert: true, badge: true, sound: true);

      _onMessageSubscription = FirebaseMessaging.onMessage.listen((
        RemoteMessage message,
      ) {
        _showForegroundNotification(message);
      });

      _onMessageOpenedSubscription =
          FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        final String itemName =
            (message.data['itemName'] as String?)?.trim() ?? '';
        if (itemName.isNotEmpty) {
          _showSnack('Reminder opened: $itemName');
        }
      });

      _onTokenRefreshSubscription = _messaging.onTokenRefresh.listen((
        String token,
      ) {
        final String? uid = _uid;
        if (uid == null || token.isEmpty) return;
        unawaited(_saveFcmToken(uid, token));
      });

      final RemoteMessage? initialMessage =
          await _messaging.getInitialMessage();
      if (initialMessage != null) {
        final String itemName =
            (initialMessage.data['itemName'] as String?)?.trim() ?? '';
        if (itemName.isNotEmpty) {
          _showSnack('Opened from reminder: $itemName');
        }
      }
    } catch (e) {
      debugPrint('FCM init failed: $e');
    }

    // Notification system is ready as long as we reach this point.
    // On web: uses in-app notification overlay.
    // On mobile: uses flutter_local_notifications + FCM.
    _notificationReady = true;
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final RemoteNotification? n = message.notification;
    final String title = n?.title ?? 'Expiry reminder';
    final String body = n?.body ??
        ((message.data['itemName'] as String?)?.isNotEmpty == true
            ? '${message.data['itemName']} is close to expiry.'
            : 'You have items that need attention.');
    if (_localNotifAvailable) {
      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _reminderChannel.id,
          _reminderChannel.name,
          channelDescription: _reminderChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      );
      await _localNotifications.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        details,
      );
    } else {
      _showInAppNotification(title: title, body: body);
    }
  }

  /// Shows an in-app notification overlay (used on Web/Desktop where
  /// flutter_local_notifications is not available).
  void _showInAppNotification({
    required String title,
    required String body,
  }) {
    _messengerKey.currentState?.clearSnackBars();
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        elevation: 12,
        content: Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.notifications_active,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF475569),
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'DISMISS',
          textColor: const Color(0xFF0EA5E9),
          onPressed: () {},
        ),
      ),
    );
  }

  /// ── Local expiry-reminder notifications ──────────────────────────
  /// Fires a pop-up notification (Telegram / WhatsApp style) for
  /// food items that are at-risk (≤ 2 days) or expiring soon (≤ 4 days).
  /// Shows ONE combined notification so the most important items are always
  /// visible — urgent items listed first, then expiring-soon items.
  /// Debounced: runs at most once every 30 minutes.
  void _checkAndNotifyExpiringItems() {
    if (!_notificationReady) return;
    final DateTime now = DateTime.now();
    if (_lastExpiryNotifCheck != null &&
        now.difference(_lastExpiryNotifCheck!).inMinutes < 30) {
      return; // too soon, skip
    }
    _lastExpiryNotifCheck = now;

    final List<FoodItem> unconsumed =
        _inventory.where((FoodItem item) => !item.consumed).toList();
    if (unconsumed.isEmpty) return;

    // Collect items that need urgent attention (≤ 2 days or low freshness)
    final List<FoodItem> urgent = unconsumed
        .where((FoodItem item) => _daysToExpiry(item) <= 2 || item.freshnessScore <= 2)
        .toList();
    // Collect items expiring soon (3-4 days) but not yet urgent
    final List<FoodItem> soon = unconsumed
        .where((FoodItem item) =>
            !urgent.contains(item) && _daysToExpiry(item) <= 4)
        .toList();

    // Nothing to notify about
    if (urgent.isEmpty && soon.isEmpty) return;

    // Helper: collapse duplicates into "Name (x3)" format
    String _collapseNames(List<FoodItem> items) {
      final Map<String, int> counts = <String, int>{};
      for (final FoodItem i in items) {
        counts[i.name] = (counts[i.name] ?? 0) + 1;
      }
      return counts.entries.map((MapEntry<String, int> e) {
        return e.value > 1 ? '${e.key} (x${e.value})' : e.key;
      }).join(', ');
    }

    // Build ONE combined notification with urgent items first
    final StringBuffer body = StringBuffer();
    String title;

    if (urgent.isNotEmpty && soon.isEmpty) {
      // Only urgent items
      title = '🚨 ${urgent.length} item${urgent.length > 1 ? 's' : ''} — eat/use TODAY!';
      body.write(_collapseNames(urgent));
      body.write(' — consume these immediately before they expire or spoil!');
    } else if (urgent.isEmpty && soon.isNotEmpty) {
      // Only expiring-soon items
      title = '🕐 ${soon.length} item${soon.length > 1 ? 's' : ''} expiring soon';
      body.write(_collapseNames(soon));
      body.write(' — plan to use them in the next few days!');
    } else {
      // Both urgent AND soon
      title = '🚨 ${urgent.length} urgent + ${soon.length} expiring soon';
      body.write('EAT TODAY: ${_collapseNames(urgent)}');
      body.write('\nUse soon: ${_collapseNames(soon)}');
    }

    _fireLocalNotification(
      id: 'expiry_combined'.hashCode,
      title: title,
      body: body.toString(),
    );
  }

  /// ── Scheduled expiry reminders (work even when app is closed) ──────
  /// Cancels all pending scheduled notifications and re-schedules
  /// reminders at 9:00 AM local time for:
  ///   • 2 days before expiry
  ///   • 1 day before expiry ("tomorrow")
  ///   • Day of expiry
  Future<void> _scheduleExpiryReminders() async {
    if (!_notificationReady || kIsWeb || !_localNotifAvailable) return;

    // Cancel only previously scheduled reminders (not immediate ones)
    for (final int id in _scheduledNotifIds) {
      await _localNotifications.cancel(id);
    }
    _scheduledNotifIds.clear();

    final List<FoodItem> unconsumed =
        _inventory.where((FoodItem item) => !item.consumed).toList();
    if (unconsumed.isEmpty) return;

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    int scheduled = 0;

    for (final FoodItem item in unconsumed) {
      // Schedule up to 3 reminders per item: 2-day, 1-day, and same-day
      final List<_ScheduledReminder> reminders = <_ScheduledReminder>[
        _ScheduledReminder(
          daysBeforeExpiry: 2,
          title: '📋 ${item.name} — expires in 2 days',
          body: 'Plan to cook or eat ${item.name} (qty ${item.quantity}) soon!',
        ),
        _ScheduledReminder(
          daysBeforeExpiry: 1,
          title: '⚠️ ${item.name} — expires TOMORROW',
          body: '${item.name} expires tomorrow! Use it today or it goes to waste.',
        ),
        _ScheduledReminder(
          daysBeforeExpiry: 0,
          title: '🚨 ${item.name} — expires TODAY!',
          body: 'Last chance! ${item.name} (qty ${item.quantity}) expires today. Eat it now!',
        ),
      ];

      for (final _ScheduledReminder r in reminders) {
        final DateTime targetDate =
            item.expiryDate.subtract(Duration(days: r.daysBeforeExpiry));
        // Schedule at 9:00 AM on the target date
        final tz.TZDateTime scheduledTime = tz.TZDateTime(
          tz.local,
          targetDate.year,
          targetDate.month,
          targetDate.day,
          9, // 9 AM
        );

        // Skip if the scheduled time is in the past
        if (scheduledTime.isBefore(now)) continue;

        // Unique ID per item per reminder type
        final int notifId =
            '${item.id}_${r.daysBeforeExpiry}'.hashCode.abs() % 2147483647;

        try {
          await _localNotifications.zonedSchedule(
            notifId,
            r.title,
            r.body,
            scheduledTime,
            NotificationDetails(
              android: AndroidNotificationDetails(
                _reminderChannel.id,
                _reminderChannel.name,
                channelDescription: _reminderChannel.description,
                importance: Importance.high,
                priority: Priority.high,
                styleInformation: BigTextStyleInformation(r.body),
              ),
              iOS: const DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: null,
          );
          scheduled++;
          _scheduledNotifIds.add(notifId);
        } catch (e) {
          debugPrint('Schedule notification failed: $e');
        }
      }
    }
    debugPrint('Scheduled $scheduled expiry reminder(s) for ${unconsumed.length} item(s).');
  }

  Future<void> _fireLocalNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    if (_localNotifAvailable) {
      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _reminderChannel.id,
          _reminderChannel.name,
          channelDescription: _reminderChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );
      try {
        await _localNotifications.show(id, title, body, details);
      } catch (e) {
        debugPrint('Local notification failed: $e');
      }
    } else {
      // Web/Desktop fallback: show in-app notification overlay
      _showInAppNotification(title: title, body: body);
    }
  }

  Future<void> _registerDeviceTokenIfPossible() async {
    final String? uid = _uid;
    if (uid == null) return;
    try {
      final String vapidKey = (dotenv.env['WEB_PUSH_VAPID_KEY'] ?? '').trim();
      final String? token = kIsWeb
          ? await _messaging.getToken(vapidKey: vapidKey.isEmpty ? null : vapidKey)
          : await _messaging.getToken();
      if (token == null || token.isEmpty) return;
      await _saveFcmToken(uid, token);
    } catch (_) {
      if (kIsWeb) {
        _showSnack(
          'FCM token registration skipped on Web. Set WEB_PUSH_VAPID_KEY in .env.',
          isError: true,
        );
      } else {
        _showSnack('FCM token registration skipped.', isError: true);
      }
    }
  }

  Future<void> _saveFcmToken(String uid, String token) {
    return FirebaseFirestore.instance.collection('users').doc(uid).set(
      <String, dynamic>{
        'fcm_token': token,
        'fcm_tokens': FieldValue.arrayUnion(<String>[token]),
        'notification_token_updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
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
      setState(() {
        _selectedImageFile = picked;
        _selectedImageLabel = picked.name;
      });
    } catch (_) {
      _showSnack('Image picker failed in Live Mode.', isError: true);
    }
  }

  Future<void> _pickImageFromCamera() async {
    if (_demoMode) {
      setState(() {
        _selectedImageFile = null;
        _selectedImageLabel = 'camera_fridge_photo.jpg';
      });
      return;
    }
    try {
      final XFile? picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1536,
        maxHeight: 1536,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _selectedImageFile = picked;
        _selectedImageLabel = picked.name;
      });
    } catch (e) {
      _showSnack('Camera failed: $e', isError: true);
    }
  }

  /// Opens a barcode scanner overlay. When a barcode is detected, it uses
  /// Gemini AI to look up the product name and estimated expiry, then adds
  /// the item directly to inventory.
  Future<void> _scanBarcode() async {
    // On web, fall back to demo mock since MobileScanner doesn't work.
    if (kIsWeb && _demoMode) {
      setState(() {
        _inventory.add(FoodItem(
          id: 'barcode_demo_${DateTime.now().millisecondsSinceEpoch}',
          name: 'Barcode Item (Demo)',
          quantity: 1,
          expiryDate: DateTime.now().add(const Duration(days: 5)),
          freshnessScore: 4,
        ));
        _liveStatusMessage = null;
        _step = DemoStep.inventory;
      });
      _showSnack('Demo barcode item added!');
      return;
    }

    // Always open real camera barcode scanner on mobile
    String? barcodeValue;
    try {
      final NavigatorState navigator = _navigatorKey.currentState!;
      barcodeValue = await navigator.push<String>(
        MaterialPageRoute<String>(
          builder: (BuildContext context) => const _BarcodeScannerScreen(),
        ),
      );
    } catch (e) {
      debugPrint('Barcode scanner error: $e');
      _showSnack('Could not open barcode scanner: $e', isError: true);
      return;
    }

    if (barcodeValue == null || barcodeValue.isEmpty || !mounted) return;
    _showSnack('Barcode detected: $barcodeValue. Looking up product...');

    setState(() {
      _processing = true;
      _step = DemoStep.processing;
    });

    // In demo mode on mobile: use scanned barcode but skip Gemini lookup
    if (_demoMode) {
      if (!mounted) return;
      final FoodItem item = FoodItem(
        id: 'barcode_${barcodeValue}_${DateTime.now().millisecondsSinceEpoch}',
        name: 'Scanned Product ($barcodeValue)',
        quantity: 1,
        expiryDate: DateTime.now().add(const Duration(days: 7)),
        freshnessScore: 3,
      );
      setState(() {
        _inventory.add(item);
        _processing = false;
        _liveStatusMessage = null;
        _step = DemoStep.inventory;
      });
      _checkAndNotifyExpiringItems();
      _showSnack('Added scanned product from barcode!');
      return;
    }

    try {
      // Use Gemini to identify the product from the barcode
      final Map<String, dynamic> result =
          await GeminiService.instance.analyzeBarcode(barcode: barcodeValue)
              .timeout(const Duration(seconds: 15));

      final String name =
          ((result['name'] as String?) ?? 'Unknown Product').trim();
      final int freshness =
          (result['freshness_score'] as int?) ?? 3;
      final int days =
          (result['estimated_expiry_days'] as int?) ?? 7;
      String? expiryStr = result['expiry_date'] as String?;
      DateTime expiryDate;
      if (expiryStr != null && expiryStr.isNotEmpty) {
        final DateTime? parsed = DateTime.tryParse(expiryStr);
        expiryDate = parsed ?? DateTime.now().add(Duration(days: days));
      } else {
        expiryDate = DateTime.now().add(Duration(days: days));
      }

      final FoodItem item = FoodItem(
        id: 'barcode_${barcodeValue}_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        quantity: 1,
        expiryDate: expiryDate,
        freshnessScore: freshness.clamp(1, 5),
      );

      if (!mounted) return;
      setState(() {
        _inventory.add(item);
        _processing = false;
        _liveStatusMessage = null;
        _step = DemoStep.inventory;
      });

      _checkAndNotifyExpiringItems();
      unawaited(_scheduleExpiryReminders());

      // Persist to Firestore
      if (_uid != null) {
        unawaited(
          FirebaseFirestore.instance
              .collection('users')
              .doc(_uid!)
              .collection('inventory')
              .doc(item.id)
              .set(<String, dynamic>{
            'name': item.name,
            'quantity': item.quantity,
            'estimated_expiry': Timestamp.fromDate(item.expiryDate),
            'freshness_score': item.freshnessScore,
            'status': 'active',
            'barcode': barcodeValue,
            'scanned_at': FieldValue.serverTimestamp(),
          }).catchError((Object e) {
            debugPrint('Barcode item Firestore save failed: $e');
          }),
        );
      }

      _showSnack('Added $name from barcode scan!');
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _step = DemoStep.scan;
      });
      _showSnack('Barcode lookup timed out. Try again.', isError: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _step = DemoStep.scan;
      });
      _showSnack('Barcode lookup failed: $e', isError: true);
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
        _stats.totalScans += 1;
        _processing = false;
        _liveStatusMessage = null;
        _step = DemoStep.inventory;
      });
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
    if (item.consumed) return const Color(0xFFE8EDF5);
    if (_isAtRisk(item)) return const Color(0xFFFEE2E2);
    if (_daysToExpiry(item) <= 4) return const Color(0xFFFEF3C7);
    return const Color(0xFFE0F2FE);
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
    // Reschedule reminders (consumed item no longer needs alerts)
    unawaited(_scheduleExpiryReminders());
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

  /// Returns a map of { lowercased-name : { 'display': 'Milk', 'count': 3 } }
  /// for items that expired 2+ times in the last 14 days.
  Map<String, Map<String, dynamic>> _getRepeatedExpiryItems() {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTime cutoff = today.subtract(const Duration(days: 14));
    final Map<String, int> expiredCountsByName = <String, int>{};
    final Map<String, String> displayNameByKey = <String, String>{};

    for (final FoodItem item in _inventory) {
      if (item.consumed) continue;
      final DateTime expiry = DateUtils.dateOnly(item.expiryDate);
      if (expiry.isBefore(cutoff)) continue;
      if (_daysToExpiry(item) >= 0) continue;

      final String key = item.name.trim().toLowerCase();
      if (key.isEmpty) continue;
      expiredCountsByName[key] = (expiredCountsByName[key] ?? 0) + 1;
      displayNameByKey.putIfAbsent(key, () => item.name.trim());
    }

    final Map<String, Map<String, dynamic>> result = <String, Map<String, dynamic>>{};
    expiredCountsByName.forEach((String key, int count) {
      if (count >= 2) {
        result[key] = <String, dynamic>{
          'display': displayNameByKey[key] ?? key,
          'count': count,
        };
      }
    });
    return result;
  }

  /// Returns true if this item name has expired 2+ times in last 14 days.
  bool _isRepeatExpirer(FoodItem item) {
    final String key = item.name.trim().toLowerCase();
    return _getRepeatedExpiryItems().containsKey(key);
  }

  String? _buildRepeatedExpiryBuyLessSuggestion() {
    final Map<String, Map<String, dynamic>> repeats = _getRepeatedExpiryItems();
    if (repeats.isEmpty) return null;

    // Pick the worst offender for the suggestion text
    String? worstKey;
    int bestCount = 0;
    repeats.forEach((String key, Map<String, dynamic> data) {
      final int count = data['count'] as int;
      if (count > bestCount) {
        bestCount = count;
        worstKey = key;
      }
    });

    if (worstKey == null) return null;
    final String displayName = repeats[worstKey]!['display'] as String;
    return 'Buy less $displayName next time (it expired $bestCount time${bestCount > 1 ? 's' : ''} in the last 2 weeks).';
  }

  /// Builds a smart grocery list: items to reduce + items running low.
  List<Map<String, dynamic>> _buildSmartGroceryList() {
    final Map<String, Map<String, dynamic>> repeats = _getRepeatedExpiryItems();
    final List<Map<String, dynamic>> groceryItems = <Map<String, dynamic>>[];

    // 1) Items to BUY LESS — expired repeatedly
    for (final MapEntry<String, Map<String, dynamic>> entry in repeats.entries) {
      groceryItems.add(<String, dynamic>{
        'name': entry.value['display'] as String,
        'action': 'buy_less',
        'reason': 'Expired ${entry.value['count']}x in 2 weeks',
        'count': entry.value['count'] as int,
      });
    }

    // 2) Items that are CONSUMED and could be restocked
    // (consumed items that are NOT repeat expirers = user actually used them)
    final Set<String> repeatKeys = repeats.keys.toSet();
    final Map<String, int> consumedCounts = <String, int>{};
    final Map<String, String> consumedDisplay = <String, String>{};
    for (final FoodItem item in _inventory) {
      if (!item.consumed) continue;
      final String key = item.name.trim().toLowerCase();
      if (key.isEmpty || repeatKeys.contains(key)) continue;
      consumedCounts[key] = (consumedCounts[key] ?? 0) + 1;
      consumedDisplay.putIfAbsent(key, () => item.name.trim());
    }
    consumedCounts.forEach((String key, int count) {
      groceryItems.add(<String, dynamic>{
        'name': consumedDisplay[key] ?? key,
        'action': 'restock',
        'reason': 'Used ${count}x — restock for next time',
        'count': count,
      });
    });

    // Sort: buy_less first, then restock by count descending
    groceryItems.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final int aOrder = a['action'] == 'buy_less' ? 0 : 1;
      final int bOrder = b['action'] == 'buy_less' ? 0 : 1;
      if (aOrder != bOrder) return aOrder.compareTo(bOrder);
      return (b['count'] as int).compareTo(a['count'] as int);
    });

    return groceryItems;
  }

  List<String> _buildSuggestions() {
    final String? buyLessSuggestion = _buildRepeatedExpiryBuyLessSuggestion();

    if (!_demoMode && _liveSuggestions.length == 3) {
      if (buyLessSuggestion == null) return _liveSuggestions;
      return <String>[
        _liveSuggestions[0],
        _liveSuggestions[1],
        buyLessSuggestion,
      ];
    }
    final List<FoodItem> candidates = _sortedCandidatesForSuggestions();
    if (candidates.isEmpty) {
      final List<String> defaults = <String>[
        'Run a new scan to refill inventory.',
        'Plan one quick meal for tonight.',
        'Track leftovers right after eating.',
      ];
      if (buyLessSuggestion == null) return defaults;
      return <String>[defaults[0], defaults[1], buyLessSuggestion];
    }
    final FoodItem first = candidates[0];
    final FoodItem second = candidates.length > 1 ? candidates[1] : first;
    final FoodItem third = candidates.length > 2 ? candidates[2] : second;
    final List<String> baseSuggestions = <String>[
      'Cook ${first.name} today.',
      'Use ${second.name} in a quick dish.',
      _isAtRisk(third)
          ? 'Save ${third.name} before tomorrow.'
          : 'Prep ${third.name} for tomorrow.',
    ];
    if (buyLessSuggestion == null) return baseSuggestions;
    return <String>[baseSuggestions[0], baseSuggestions[1], buyLessSuggestion];
  }

  List<FoodItem> _itemsForMarkConsumed() {
    final List<FoodItem> prioritized = _sortedCandidatesForSuggestions();
    if (prioritized.isEmpty) return <FoodItem>[];
    // Show all unconsumed items, at-risk items first.
    final List<FoodItem> atRisk =
        prioritized.where((FoodItem item) => _isAtRisk(item)).toList();
    final List<FoodItem> rest =
        prioritized.where((FoodItem item) => !_isAtRisk(item)).toList();
    return <FoodItem>[...atRisk, ...rest];
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
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('User is not authenticated. Please sign in first.');
      }
      _uid = user.uid;
      await _registerDeviceTokenIfPossible();
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
        // Check for expiring items and push notifications
        _checkAndNotifyExpiringItems();
        // Schedule background reminders that fire even when app is closed
        unawaited(_scheduleExpiryReminders());
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
    return FoodItem(
      id: doc.id.isEmpty ? 'item_$index' : doc.id,
      name: ((data['name'] as String?) ?? 'Unknown Item').trim(),
      quantity: quantity < 1 ? 1 : quantity,
      expiryDate: expiryDate,
      freshnessScore: freshness,
      consumed: status == 'consumed',
    );
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
        'estimated_expiry_days': days,
        'reminder_target': Timestamp.fromDate(
          now.add(Duration(days: days <= 1 ? 0 : days - 1)),
        ),
        'reminder_sent': false,
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

  /// Compress image bytes to a target max dimension and JPEG quality.
  /// This uses Flutter's built-in dart:ui codec — no extra packages needed.
  /// Keeps enough detail for Gemini to read labels/brands/expiry dates,
  /// while reducing size from ~3-5MB to ~100-300KB.
  Future<Uint8List> _compressImageForAI(
    Uint8List original, {
    int maxDimension = 1024,
    int quality = 75,
  }) async {
    try {
      // Decode the image
      final ui.Codec codec = await ui.instantiateImageCodec(
        original,
        targetWidth: maxDimension,
        targetHeight: maxDimension,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;

      // Encode to JPEG-equivalent PNG (dart:ui toByteData)
      // Use PNG format from dart:ui, then re-encode if needed
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData == null) {
        debugPrint('Image compression failed — using original bytes');
        return original;
      }

      final Uint8List pngBytes = byteData.buffer.asUint8List();
      debugPrint('Compressed to PNG: ${(pngBytes.lengthInBytes / 1024).toStringAsFixed(0)} KB '
          '(${image.width}x${image.height})');

      // If PNG is still smaller than original, use it; otherwise use original
      return pngBytes.lengthInBytes < original.lengthInBytes
          ? pngBytes
          : original;
    } catch (e) {
      debugPrint('Image compression error: $e — using original');
      return original;
    }
  }

  int _scanRetryAttempt = 0;
  static const int _maxScanRetries = 2;

  Future<void> _startLiveProcessing() async {
    if (_processing) return;
    if (_geminiQuotaBlockedUntil != null &&
        DateTime.now().isBefore(_geminiQuotaBlockedUntil!)) {
      // Auto-wait for cooldown then retry
      await _waitForQuotaCooldownThenRetry();
      return;
    }
    final bool ready = await _ensureLiveModeReady();
    if (!ready) {
      if (!mounted) return;
      setState(() {
        _demoMode = true;
      });
      _showSnack('Live mode failed. Fallback to Demo Mode.', isError: true);
      return;
    }
    XFile? selected = _selectedImageFile;
    if (selected == null) {
      selected = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1536,
        maxHeight: 1536,
        imageQuality: 85,
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
      final Uint8List rawBytes = await selected.readAsBytes();
      debugPrint('Scan image ORIGINAL size: ${(rawBytes.lengthInBytes / 1024).toStringAsFixed(0)} KB');

      // Compress image to ~800px max dimension & JPEG quality 75
      // This keeps Gemini accuracy high while drastically reducing upload time.
      if (mounted) {
        setState(() {
          _liveStatusMessage = 'Compressing image...';
        });
      }
      final Uint8List bytes = await _compressImageForAI(rawBytes, maxDimension: 1024, quality: 75);
      debugPrint('Scan image COMPRESSED size: ${(bytes.lengthInBytes / 1024).toStringAsFixed(0)} KB');

      // Upload is optional for UX; do not block scan completion on slow network.
      unawaited(
        ref
            .putData(bytes, SettableMetadata(contentType: 'image/jpeg'))
            .catchError((Object uploadError) {
              debugPrint('Background scan upload failed: $uploadError');
            }),
      );

      if (mounted) {
        setState(() {
          _liveStatusMessage = 'Sending image to Gemini AI for analysis...';
        });
      }

      final Map<String, dynamic> geminiResult = await GeminiService.instance
          .analyzeFridgeImage(imageBytes: bytes)
          .timeout(const Duration(seconds: 60));

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

      _scanRetryAttempt = 0; // Reset retry counter on success
      if (!mounted) return;
      setState(() {
        _inventory
          ..clear()
          ..addAll(localItems);
        _stats.totalScans += 1;
        _processing = false;
        _liveStatusMessage = null;
        _step = DemoStep.inventory;
      });

      // Push local notifications for items close to expiry
      _checkAndNotifyExpiringItems();
      // Schedule background reminders that fire even when app is closed
      unawaited(_scheduleExpiryReminders());

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
      _showSnack('Scan timed out after 60s. Please try again — Gemini may be under heavy load.', isError: true);
    } catch (error) {
      final String raw = 'Live scan failed: $error';
      _applyQuotaCooldownFromError(raw);
      if (_isQuotaError(raw) && _scanRetryAttempt < _maxScanRetries) {
        // Auto-retry after cooldown
        _scanRetryAttempt++;
        if (!mounted) return;
        setState(() {
          _processing = false;
        });
        await _waitForQuotaCooldownThenRetry();
        return;
      }
      _scanRetryAttempt = 0;
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

  /// Wait for quota cooldown with a live countdown, then auto-retry the scan.
  Future<void> _waitForQuotaCooldownThenRetry() async {
    if (!mounted) return;
    setState(() {
      _processing = true;
      _step = DemoStep.processing;
    });
    while (_geminiQuotaBlockedUntil != null &&
        DateTime.now().isBefore(_geminiQuotaBlockedUntil!) &&
        mounted) {
      final int remaining = _quotaCooldownRemainingSeconds;
      setState(() {
        _liveStatusMessage =
            'Gemini quota cooling down... auto-retrying in ${remaining}s';
      });
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() {
      _processing = false;
      _liveStatusMessage = 'Retrying scan...';
    });
    // Clear the cooldown and retry
    _geminiQuotaBlockedUntil = null;
    return _startLiveProcessing();
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
    return _glassCard(
      blur: 24,
      opacity: 0.5,
      borderRadius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: List<Widget>.generate(steps.length, (int index) {
          final DemoStep step = steps[index];
          final bool isActive = index == currentIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            child: FilterChip(
              selected: isActive,
              showCheckmark: false,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              onSelected: (_) => _setStep(step),
              selectedColor: theme.colorScheme.primary.withOpacity(0.18),
              backgroundColor: Colors.white.withOpacity(0.35),
              side: BorderSide(
                color: isActive
                    ? theme.colorScheme.primary.withOpacity(0.5)
                    : Colors.white.withOpacity(0.6),
                width: isActive ? 1.5 : 1.0,
              ),
              avatar: Icon(
                _stepIcon(step),
                size: 13,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              label: Text(
                _stepLabel(step),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Glassmorphism helper ──────────────────────────────────────────────
  Widget _glassCard({
    required Widget child,
    double blur = 18,
    double opacity = 0.45,
    double borderRadius = 20,
    EdgeInsetsGeometry? padding,
    Color? color,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding ?? const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: (color ?? Colors.white).withOpacity(opacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.6),
              width: 1.2,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
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
          if (_demoMode) _buildDemoBadge(),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Sign Out',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (_localNotifAvailable) {
                unawaited(_localNotifications.cancelAll());
                _scheduledNotifIds.clear();
              }
              if (!mounted) return;
              setState(() {
                _isAuthenticated = false;
                _uid = null;
                _liveInventorySubscription?.cancel();
                _liveInventorySubscription = null;
                _inventory.clear();
                _step = DemoStep.home;
              });
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: <Widget>[
          // ── Beautiful gradient mesh background ──
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    Color(0xFFE0F2FE), // light sky blue
                    Color(0xFFF0F4FF), // soft lavender
                    Color(0xFFEDE9FE), // light violet
                    Color(0xFFFEF3C7), // warm amber glow
                  ],
                  stops: <double>[0.0, 0.35, 0.7, 1.0],
                ),
              ),
            ),
          ),
          // ── Floating orb top-left (cyan/teal) ──
          Positioned(
            top: -100,
            left: -80,
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    const Color(0xFF0EA5E9).withOpacity(0.25),
                    const Color(0xFF0EA5E9).withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          // ── Floating orb bottom-right (violet) ──
          Positioned(
            right: -120,
            bottom: -140,
            child: Container(
              width: 420,
              height: 420,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    const Color(0xFF8B5CF6).withOpacity(0.2),
                    const Color(0xFF8B5CF6).withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          // ── Floating orb center-right (amber) ──
          Positioned(
            right: -60,
            top: 200,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    const Color(0xFFF59E0B).withOpacity(0.12),
                    const Color(0xFFF59E0B).withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          // ── Content ──
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildStepIndicator(),
                      if (showSectionHeader) ...<Widget>[
                        const SizedBox(height: 20),
                        _glassCard(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                sectionTitle,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                sectionSubtitle,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
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
    return _glassCard(
      borderRadius: 18,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 10),
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
          const SizedBox(height: 14),
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontSize: 34,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
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
      backgroundColor: Colors.white.withOpacity(0.5),
      side: BorderSide(color: Colors.white.withOpacity(0.7)),
    );
  }

  Widget _miniInfoChip({
    required IconData icon,
    required String text,
    Color? color,
    Color? textColor,
  }) {
    final ThemeData theme = Theme.of(context);
    final Color bg = color ?? Colors.white.withOpacity(0.5);
    final Color fg = textColor ?? theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: fg,
              fontWeight: textColor != null ? FontWeight.w700 : null,
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
        color: Color(0xFF1A1D26),
      ),
      headlineSmall: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        height: 1.15,
        color: Color(0xFF1A1D26),
      ),
      titleLarge: TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w800,
        color: Color(0xFF1A1D26),
      ),
      titleMedium: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1A1D26),
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: Color(0xFF4A5568),
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: Color(0xFF4A5568),
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1A1D26),
      ),
    );

    // Glass-morphism light palette with soft pastels
    final ColorScheme scheme = const ColorScheme(
      brightness: Brightness.light,
      // Core surfaces — translucent whites for glass effect
      surface: Color(0xFFF0F4FF),           // Soft lavender-white background
      onSurface: Color(0xFF1A1D26),
      surfaceContainerLowest: Color(0xFFFFFFFF),
      surfaceContainerLow: Color(0xFFF7F9FF),
      surfaceContainer: Color(0xFFF0F4FF),
      surfaceContainerHigh: Color(0xFFE8EEFF),      // Glass card / light frost
      surfaceContainerHighest: Color(0xFFDFE7FF),   // Deeper glass card
      onSurfaceVariant: Color(0xFF5B6478),
      inverseSurface: Color(0xFF1A1D26),
      onInverseSurface: Color(0xFFF0F4FF),
      // Primary — vibrant teal/cyan gradient anchor
      primary: Color(0xFF0EA5E9),           // Sky blue
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFFE0F2FE),  // Very light blue
      onPrimaryContainer: Color(0xFF0369A1),
      inversePrimary: Color(0xFF7DD3FC),
      // Secondary — soft violet
      secondary: Color(0xFF8B5CF6),         // Violet
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFFEDE9FE),// Light violet
      onSecondaryContainer: Color(0xFF6D28D9),
      // Tertiary — warm amber/orange
      tertiary: Color(0xFFF59E0B),          // Amber
      onTertiary: Color(0xFFFFFFFF),
      tertiaryContainer: Color(0xFFFEF3C7), // Light amber
      onTertiaryContainer: Color(0xFFB45309),
      // Error
      error: Color(0xFFEF4444),
      onError: Color(0xFFFFFFFF),
      errorContainer: Color(0xFFFEE2E2),
      onErrorContainer: Color(0xFFB91C1C),
      // Outlines and shadows
      outline: Color(0xFFCBD5E1),
      outlineVariant: Color(0xFFE2E8F0),
      shadow: Color(0x1A000000),
      scrim: Color(0x33000000),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF0F4FF),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: const Color(0xFF1A1D26),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: appTextTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: const Color(0xFF1A1D26),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white.withOpacity(0.55),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withOpacity(0.6)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          side: BorderSide(color: scheme.outline.withOpacity(0.5)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withOpacity(0.5),
        side: BorderSide(color: Colors.white.withOpacity(0.6)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      textTheme: appTextTheme,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      title: 'FridgeGuardian',
      theme: _buildTheme(Brightness.light),
      themeMode: ThemeMode.light,
      home: _isAuthenticated ? _buildCurrentScreen() : AuthScreen(
        onAuthenticated: (User user) {
          setState(() {
            _isAuthenticated = true;
            _uid = user.uid;
          });
        },
      ),
    );
  }

  Widget _buildCurrentScreen() {
    final Widget screen;
    switch (_step) {
      case DemoStep.home:
        screen = _buildHomeScreen();
      case DemoStep.scan:
        screen = _buildScanScreen();
      case DemoStep.processing:
        screen = _buildProcessingScreen();
      case DemoStep.inventory:
        screen = _buildInventoryScreenStable();
      case DemoStep.suggestions:
        screen = _buildSuggestionsScreen();
      case DemoStep.dashboard:
        screen = _buildDashboardScreen();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        final Animation<Offset> slideAnimation = Tween<Offset>(
          begin: const Offset(0.06, 0.0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const ElasticOutCurve(0.85),
        ));
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: slideAnimation,
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<DemoStep>(_step),
        child: screen,
      ),
    );
  }

  /// Staggered spring entrance for list items.
  Widget _springEntrance({
    required Widget child,
    required int index,
    int delayMs = 60,
    int durationMs = 600,
  }) {
    return TweenAnimationBuilder<double>(
      key: ValueKey<String>('spring_${_step.name}_$index'),
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: durationMs + (index * delayMs)),
      curve: const ElasticOutCurve(0.8),
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, 24 * (1 - value)),
            child: Transform.scale(
              scale: 0.95 + (0.05 * value),
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildHomeScreen() {
    final ThemeData theme = Theme.of(context);
    return _buildShell(
      sectionTitle: 'Smart Food Management',
      sectionSubtitle: 'Scan your fridge, prioritize expiring items, reduce waste.',
      showSectionHeader: false,
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              children: <Widget>[
                _springEntrance(
                  index: 0,
                  child: _glassCard(
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
                const SizedBox(height: 20),
                _springEntrance(
                  index: 1,
                  child: _glassCard(
                    padding: EdgeInsets.zero,
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
                ),
                if (_liveStatusMessage != null) ...<Widget>[
                  const SizedBox(height: 12),
                  _springEntrance(
                    index: 2,
                    child: _glassCard(
                      color: theme.colorScheme.errorContainer,
                      opacity: 0.85,
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _liveStatusMessage!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                _springEntrance(
                  index: 3,
                  child: _buildKpiGrid(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _springEntrance(
            index: 4,
            child: _glassCard(
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
                _springEntrance(
                  index: 0,
                  child: _glassCard(
                    padding: EdgeInsets.zero,
                    child: Container(
                      height: 300,
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.photo_camera_rounded,
                              size: 56,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 14),
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
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: _pickImage,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.photo_library_outlined),
                        SizedBox(width: 8),
                        Text('Gallery'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: _pickImageFromCamera,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.camera_alt_rounded),
                        SizedBox(width: 8),
                        Text('Camera'),
                      ],
                    ),
                  ),
                ),
              ],
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
          FilledButton.icon(
            onPressed: _scanBarcode,
            icon: const Icon(Icons.barcode_reader),
            label: const Text('Scan Barcode / Expiry'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.tertiary,
              foregroundColor: Theme.of(context).colorScheme.onTertiary,
            ),
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
        child: _springEntrance(
          index: 0,
          durationMs: 800,
          child: _glassCard(
            blur: 24,
            opacity: 0.55,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: theme.colorScheme.primary,
                ),
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
                    : 'Gemini AI is studying your fridge — this may take up to 60 seconds for a detailed analysis.',
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
    final ColorScheme scheme = theme.colorScheme;
    final List<FoodItem> visible =
        _inventory.where((FoodItem i) => !i.consumed).toList();
    final List<FoodItem> atRisk = visible.where(_isAtRisk).toList();

    return _buildShell(
      sectionTitle: 'Inventory',
      sectionSubtitle: '${visible.length} items scanned${atRisk.isNotEmpty ? ' · ${atRisk.length} at risk' : ''}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (atRisk.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2).withOpacity(0.7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.25)),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 16),
                  const SizedBox(width: 6),
                  Text(
                    '${atRisk.length} item${atRisk.length == 1 ? '' : 's'} at risk — use today',
                    style: const TextStyle(
                      color: Color(0xFF991B1B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          if (visible.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.inbox_rounded, size: 40, color: scheme.onSurfaceVariant.withOpacity(0.4)),
                    const SizedBox(height: 8),
                    Text('No items yet', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    Text('Run a scan to add items.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: visible.length,
                itemBuilder: (BuildContext context, int index) {
                  final FoodItem item = visible[index];
                  final int days = _daysToExpiry(item);
                  final bool risk = _isAtRisk(item);
                  final bool soon = !risk && days <= 4;

                  return Container(
                    key: ValueKey<String>('inv_${item.id}_$index'),
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: risk
                          ? const Color(0xFFFEE2E2).withOpacity(0.3)
                          : Colors.white.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: risk
                            ? const Color(0xFFEF4444).withOpacity(0.25)
                            : Colors.white.withOpacity(0.6),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        // Color dot
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: risk
                                ? const Color(0xFFEF4444)
                                : soon
                                    ? scheme.tertiary
                                    : const Color(0xFF10B981),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Name + buy-less badge
                        Expanded(
                          flex: 3,
                          child: Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  item.name,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (_isRepeatExpirer(item)) ...[
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEF4444),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'BUY LESS',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 7,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Expiry
                        Text(
                          '${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: risk ? const Color(0xFFEF4444) : scheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Status
                        SizedBox(
                          width: 62,
                          child: Text(
                            risk ? 'Use TODAY!' : soon ? '$days day(s)' : 'Qty ${item.quantity}',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: risk || soon ? FontWeight.w700 : FontWeight.normal,
                              color: risk
                                  ? const Color(0xFFEF4444)
                                  : soon
                                      ? scheme.tertiary
                                      : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 4),
          SizedBox(
            height: 38,
            child: FilledButton.icon(
              onPressed: visible.isEmpty ? null : _goToSuggestions,
              icon: const Icon(Icons.lightbulb_rounded, size: 16),
              label: const Text('Continue to Suggestions', style: TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              onPressed: _goBackStep,
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('Back', style: TextStyle(fontSize: 13)),
            ),
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
          if (_demoMode) _buildDemoBadge(),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Sign Out',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (_localNotifAvailable) {
                unawaited(_localNotifications.cancelAll());
                _scheduledNotifIds.clear();
              }
              if (!mounted) return;
              setState(() {
                _isAuthenticated = false;
                _uid = null;
                _liveInventorySubscription?.cancel();
                _liveInventorySubscription = null;
                _inventory.clear();
                _step = DemoStep.home;
              });
            },
          ),
          const SizedBox(width: 4),
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
    final titleStyle = (t.titleSmall ??
        const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        )).copyWith(fontWeight: FontWeight.w600);
    final subStyle = (t.bodySmall ??
            const TextStyle(
              fontSize: 12,
            ))
        .copyWith(color: colorScheme.onSurfaceVariant);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Compact header row
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.kitchen_rounded, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Inventory', style: titleStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('${visible.length} items', style: subStyle),
                  const Spacer(),
                  if (atRisk.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 14, color: colorScheme.onErrorContainer),
                          const SizedBox(width: 4),
                          Text(
                            '${atRisk.length} at risk',
                            style: (t.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(
                              color: colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            // Items list
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_rounded, size: 40, color: colorScheme.onSurfaceVariant.withOpacity(0.4)),
                          const SizedBox(height: 8),
                          Text('No items yet', style: subStyle),
                          Text('Run a scan to add items.', style: subStyle),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final item = visible[index];
                        return KeyedSubtree(
                          key: ValueKey('inv_${item.id}_$index'),
                          child: _buildInventoryItemCardCrashSafe(item),
                        );
                      },
                    ),
            ),
            // Bottom buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SizedBox(
                height: 40,
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: visible.isEmpty ? null : _goToSuggestions,
                  icon: const Icon(Icons.lightbulb_outline, size: 18),
                  label: const Text('Continue to Suggestions', style: TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInventoryItemCardCrashSafe(FoodItem item) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final t = theme.textTheme;
    final days = _daysToExpiry(item);
    final atRisk = _isAtRisk(item);

    final nameStyle = const TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    final smallStyle = TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: atRisk
            ? colorScheme.errorContainer.withOpacity(0.25)
            : colorScheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: atRisk
              ? colorScheme.error.withOpacity(0.3)
              : colorScheme.outlineVariant.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(
            atRisk ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            color: atRisk ? colorScheme.error : colorScheme.primary,
            size: 18,
          ),
          const SizedBox(width: 8),
          // Name
          Expanded(
            flex: 3,
            child: Text(
              item.name,
              style: nameStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          // Expiry + status
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${item.expiryDate.day}/${item.expiryDate.month}/${item.expiryDate.year}',
                  style: TextStyle(
                    fontSize: 11,
                    color: atRisk ? colorScheme.error : colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  atRisk
                      ? 'Use TODAY!'
                      : days <= 4
                          ? '$days day(s) left'
                          : 'Qty ${item.quantity}',
                  style: TextStyle(
                    fontSize: 10,
                    color: atRisk
                        ? colorScheme.error
                        : days <= 4
                            ? colorScheme.tertiary
                            : colorScheme.onSurfaceVariant,
                    fontWeight: atRisk || days <= 4 ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          if (atRisk) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'RISK',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ],
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.lightbulb_rounded, color: scheme.primary),
                    ),
                    const SizedBox(width: 10),
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
                    return _springEntrance(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _glassCard(
                          borderRadius: 16,
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: scheme.primary.withOpacity(0.12),
                              child: Icon(
                                suggestionIcons[index],
                                color: scheme.primary,
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
                      ),
                    );
                  }),
                  const SizedBox(height: 20),
                  // ── Smart Grocery List ──
                  _buildSmartGroceryListSection(theme, scheme),
                  const SizedBox(height: 20),
                  Text(
                    'Mark Consumed',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (markTargets.isEmpty)
                    _glassCard(
                      borderRadius: 16,
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No available items to consume.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    ...markTargets.map((FoodItem item) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _glassCard(
                          borderRadius: 16,
                          padding: EdgeInsets.zero,
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
    );
  }
  // ── Smart Grocery List Section (shown in Suggestions screen) ──
  Widget _buildSmartGroceryListSection(ThemeData theme, ColorScheme scheme) {
    final List<Map<String, dynamic>> groceryList = _buildSmartGroceryList();
    final List<Map<String, dynamic>> buyLessItems = groceryList
        .where((Map<String, dynamic> g) => g['action'] == 'buy_less')
        .toList();
    final List<Map<String, dynamic>> restockItems = groceryList
        .where((Map<String, dynamic> g) => g['action'] == 'restock')
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.tertiary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.shopping_cart_rounded, color: scheme.tertiary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Smart Grocery List',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'AI-powered shopping recommendations',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Buy Less section
        if (buyLessItems.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFEE2E2).withOpacity(0.7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.25)),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.trending_down_rounded, color: Color(0xFFEF4444), size: 16),
                const SizedBox(width: 6),
                Text(
                  'Buy Less — These keep expiring',
                  style: const TextStyle(
                    color: Color(0xFF991B1B),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ...buyLessItems.map((Map<String, dynamic> item) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _glassCard(
                borderRadius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.remove_shopping_cart_rounded, size: 18, color: Color(0xFFEF4444)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            item['name'] as String,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item['reason'] as String,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFEF4444),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'BUY LESS',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
        ],

        // Restock section
        if (restockItems.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFD1FAE5).withOpacity(0.7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF10B981).withOpacity(0.25)),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.add_shopping_cart_rounded, color: Color(0xFF10B981), size: 16),
                const SizedBox(width: 6),
                Text(
                  'Restock — You used these up',
                  style: const TextStyle(
                    color: Color(0xFF065F46),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ...restockItems.map((Map<String, dynamic> item) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _glassCard(
                borderRadius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1FAE5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.add_shopping_cart_rounded, size: 18, color: Color(0xFF10B981)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            item['name'] as String,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item['reason'] as String,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF10B981),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'RESTOCK',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],

        if (groceryList.isEmpty)
          _glassCard(
            borderRadius: 12,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Icon(Icons.check_circle_rounded, color: const Color(0xFF10B981), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No grocery recommendations yet.\nKeep tracking your items and we\'ll suggest what to buy more or less of!',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDashboardScreen() {
    final ThemeData theme = Theme.of(context);
    return _buildShell(
      sectionTitle: 'Dashboard',
      sectionSubtitle: 'Track scan volume, food saved, and sustainability impact.',
      body: ListView(
        children: <Widget>[
          _springEntrance(index: 0, child: _buildKpiGrid()),
          const SizedBox(height: 16),
          _springEntrance(
            index: 1,
            child: _glassCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.insights_rounded, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 10),
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
                        color: const Color(0xFFFEE2E2),
                        textColor: const Color(0xFFEF4444),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _springEntrance(
            index: 2,
            child: FilledButton.icon(
              onPressed: () => _setStep(DemoStep.scan),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Run Another Demo Scan'),
            ),
          ),
          const SizedBox(height: 12),
          _springEntrance(
            index: 3,
            child: OutlinedButton.icon(
              onPressed: () => _setStep(DemoStep.home),
              icon: const Icon(Icons.home_rounded),
              label: const Text('Back to Home'),
            ),
          ),
        ],
      ),
    );
  }
}



class _ScheduledReminder {
  const _ScheduledReminder({
    required this.daysBeforeExpiry,
    required this.title,
    required this.body,
  });
  final int daysBeforeExpiry;
  final String title;
  final String body;
}

/// Fullscreen barcode scanner screen using mobile_scanner.
class _BarcodeScannerScreen extends StatefulWidget {
  const _BarcodeScannerScreen();

  @override
  State<_BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<_BarcodeScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _hasPopped = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasPopped) return;
    final List<Barcode> barcodes = capture.barcodes;
    for (final Barcode barcode in barcodes) {
      final String? value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _hasPopped = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Barcode'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          IconButton(
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (BuildContext context, MobileScannerState state, Widget? child) {
                return Icon(
                  state.torchState == TorchState.on
                      ? Icons.flash_on_rounded
                      : Icons.flash_off_rounded,
                );
              },
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          Center(
            child: Container(
              width: 280,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Text(
              'Point camera at a barcode',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    shadows: <Shadow>[
                      const Shadow(
                        blurRadius: 8,
                        color: Colors.black87,
                      ),
                    ],
                  ),
            ),
          ),
        ],
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
