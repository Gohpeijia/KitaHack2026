import 'package:flutter/material.dart';

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
  final DemoStats _stats = DemoStats();
  final List<FoodItem> _inventory = <FoodItem>[];

  void _setStep(DemoStep step) {
    setState(() => _step = step);
  }

  void _toggleDemoMode(bool enabled) {
    setState(() => _demoMode = enabled);
  }

  void _mockPickImage() {
    setState(() => _selectedImageLabel = 'mock_fridge_photo.jpg');
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
    if (item.consumed) return const Color(0xFF1A1F2B);
    if (_isAtRisk(item)) return const Color(0xFF4B1F23);
    if (_daysToExpiry(item) <= 4) return const Color(0xFF4A321E);
    return const Color(0xFF1E2B33);
  }

  void _quickEditItem(String itemId, String newName, int newQuantity) {
    final int i = _inventory.indexWhere((FoodItem item) => item.id == itemId);
    if (i < 0) return;
    setState(() {
      final String trimmedName = newName.trim();
      if (trimmedName.isNotEmpty) _inventory[i].name = trimmedName;
      _inventory[i].quantity = newQuantity < 1 ? 1 : newQuantity;
    });
  }

  Future<void> _openQuickEditDialog(FoodItem item) async {
    final TextEditingController nameController =
        TextEditingController(text: item.name);
    final TextEditingController qtyController =
        TextEditingController(text: item.quantity.toString());
    final _QuickEditResult? result = await showDialog<_QuickEditResult>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Quick Edit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: qtyController,
              decoration: const InputDecoration(labelText: 'Quantity'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final int q = int.tryParse(qtyController.text.trim()) ?? item.quantity;
              Navigator.of(context).pop(_QuickEditResult(nameController.text, q));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    nameController.dispose();
    qtyController.dispose();
    if (result == null) return;
    _quickEditItem(item.id, result.name, result.quantity);
  }

  void _markConsumed(String itemId) {
    final int i = _inventory.indexWhere((FoodItem item) => item.id == itemId);
    if (i < 0 || _inventory[i].consumed) return;
    setState(() {
      final FoodItem item = _inventory[i];
      item.consumed = true;
      _stats.totalItemsSaved += item.quantity;
      _stats.co2eAvoidedKg += item.quantity * 0.35;
    });
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

  int get _atRiskCount => _inventory.where((FoodItem item) => _isAtRisk(item)).length;
  int get _availableCount =>
      _inventory.where((FoodItem item) => !item.consumed).length;
  int get _consumedCount =>
      _inventory.where((FoodItem item) => item.consumed).length;

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
              onSelected: (_) {},
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
    return _buildShell(
      sectionTitle: 'Smart Food Management',
      sectionSubtitle: 'Scan your fridge, prioritize expiring items, reduce waste.',
      showSectionHeader: false,
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              children: <Widget>[
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
    return _buildShell(
      sectionTitle: 'Scan',
      sectionSubtitle: 'Capture or mock your fridge image, then start the demo scan.',
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              children: <Widget>[
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Container(
                    height: 300,
                    padding: const EdgeInsets.all(24),
                    child: Column(
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
                if (!_demoMode) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'Enable Demo Mode on Home screen to continue this offline demo.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _demoMode ? _startDemoProcessing : null,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan Whole Fridge (Demo)'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _mockPickImage,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.photo_library_outlined),
                SizedBox(width: 8),
                Text('Pick Image (Optional)'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _setStep(DemoStep.home),
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
                  'Demo will complete shortly.',
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
                                          : () => _openQuickEditDialog(item),
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
            onPressed: visible.isEmpty ? null : () => _setStep(DemoStep.suggestions),
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
                                      onPressed: () => _openQuickEditDialog(item),
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
                                  style: titleStyle.copyWith(
                                    color: risk
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w800,
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
            onPressed: visible.isEmpty ? null : () => _setStep(DemoStep.suggestions),
            icon: const Icon(Icons.lightbulb_rounded),
            label: const Text('Continue to Suggestions'),
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
            onPressed: visible.isEmpty ? null : () => _setStep(DemoStep.suggestions),
            icon: const Icon(Icons.lightbulb_outline),
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
                      IconButton(
                        tooltip: 'Quick Edit',
                        onPressed: () => _openQuickEditDialog(item),
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
                    style: titleStyle.copyWith(
                      color: risk
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
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
            onPressed:
                visible.isEmpty ? null : () => _setStep(DemoStep.suggestions),
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
                    'Expires in $days day${days == 1 ? '' : 's'}',
                    style: bodyStyle.copyWith(
                      color: atRisk ? colorScheme.error : colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
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
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.lightbulb_rounded, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Top 3 actions',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Prioritized by expiring soon',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                ...List<Widget>.generate(suggestions.length, (int index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                        color: theme.colorScheme.surfaceContainerHigh,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Icon(
                            suggestionIcons[index],
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text('${index + 1}. ${suggestions[index]}'),
                        subtitle: const Text('~15 min'),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
                Text(
                  'Mark Consumed',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (markTargets.isEmpty)
                  Card(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No available items to consume.'),
                    ),
                  )
                else
                  ...markTargets.map((FoodItem item) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Card(
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: ListTile(
                          title: Text(item.name),
                          subtitle: Text(
                            'Qty ${item.quantity} | Freshness ${item.freshnessScore}/5',
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
  const _QuickEditResult(this.name, this.quantity);
  final String name;
  final int quantity;
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
