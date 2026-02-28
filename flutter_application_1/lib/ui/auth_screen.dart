import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// A polished login / register screen that matches the FridgeGuardian dark theme.
/// After successful auth the [onAuthenticated] callback is invoked with the [User].
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onAuthenticated});

  final void Function(User user) onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with TickerProviderStateMixin {
  // ── form ──────────────────────────────────────────────────────────────
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();

  bool _isLogin = true; // toggle between Login and Register
  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;

  // ── spring physics animations ─────────────────────────────────────────
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  late final AnimationController _springController;
  late final Animation<double> _springScale;
  late final Animation<Offset> _springSlide;

  late final AnimationController _logoController;
  late final Animation<double> _logoBounce;

  // ── lifecycle ─────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    // Fade animation for mode toggle
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    // Spring scale+slide for the form card (Framer Motion style)
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _springScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _springController,
        curve: const _SpringDampingCurve(stiffness: 180, damping: 14),
      ),
    );
    _springSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _springController,
        curve: const _SpringDampingCurve(stiffness: 160, damping: 16),
      ),
    );
    _springController.forward();

    // Logo elastic bounce
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _logoBounce = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const ElasticOutCurve(0.6),
      ),
    );
    _logoController.forward();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _displayNameController.dispose();
    _fadeController.dispose();
    _springController.dispose();
    _logoController.dispose();
    super.dispose();
  }

  // ── auth actions ──────────────────────────────────────────────────────
  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      UserCredential credential;
      if (_isLogin) {
        credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      } else {
        credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        // Optional: set display name if provided
        final String name = _displayNameController.text.trim();
        if (name.isNotEmpty) {
          await credential.user?.updateDisplayName(name);
        }
      }

      if (credential.user != null) {
        // Save / update user profile in Firestore
        await _saveUserProfileToFirestore(credential.user!, isNewUser: !_isLogin);
        widget.onAuthenticated(credential.user!);
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = _friendlyAuthError(e.code);
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final UserCredential credential =
          await FirebaseAuth.instance.signInAnonymously();
      if (credential.user != null) {
        // Save minimal guest profile to Firestore
        await _saveUserProfileToFirestore(credential.user!, isNewUser: true);
        widget.onAuthenticated(credential.user!);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Guest login failed: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Writes / merges the user's profile document into Firestore
  /// at `users/{uid}`. On registration (isNewUser) it writes the full
  /// profile; on login it only updates the last-login timestamp.
  Future<void> _saveUserProfileToFirestore(User user,
      {required bool isNewUser}) async {
    final DocumentReference<Map<String, dynamic>> docRef =
        FirebaseFirestore.instance.collection('users').doc(user.uid);

    if (isNewUser) {
      // Full profile on first registration
      await docRef.set(<String, dynamic>{
        'uid': user.uid,
        'email': user.email ?? '',
        'display_name': user.displayName ?? '',
        'is_anonymous': user.isAnonymous,
        'created_at': FieldValue.serverTimestamp(),
        'last_login_at': FieldValue.serverTimestamp(),
        'auth_provider':
            user.isAnonymous ? 'anonymous' : 'email_password',
      }, SetOptions(merge: true));
    } else {
      // Existing user – just bump last login
      await docRef.set(<String, dynamic>{
        'last_login_at': FieldValue.serverTimestamp(),
        'email': user.email ?? '',
        'display_name': user.displayName ?? '',
      }, SetOptions(merge: true));
    }
  }

  String _friendlyAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'email-already-in-use':
        return 'An account with this email already exists.';
      case 'weak-password':
        return 'Password is too weak (min 6 characters).';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      default:
        return 'Authentication error: $code';
    }
  }

  void _toggleMode() {
    _fadeController.reverse().then((_) {
      setState(() {
        _isLogin = !_isLogin;
        _errorMessage = null;
        _confirmPasswordController.clear();
        _displayNameController.clear();
      });
      _fadeController.forward();
    });
  }

  // ── build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // ── Explicit dark-on-light text colors for maximum readability ──
    const Color titleColor = Color(0xFF0F172A);    // near-black
    const Color subtitleColor = Color(0xFF475569);  // slate-600
    const Color labelColor = Color(0xFF334155);     // slate-700
    const Color hintColor = Color(0xFF94A3B8);      // slate-400

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
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
          // ── Floating orb top-left (cyan) ──
          Positioned(
            top: -100,
            left: -80,
            child: Container(
              width: 340,
              height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    const Color(0xFF0EA5E9).withOpacity(0.22),
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
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    const Color(0xFF8B5CF6).withOpacity(0.18),
                    const Color(0xFF8B5CF6).withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          // ── Floating orb center (amber) ──
          Positioned(
            right: 40,
            top: 180,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    const Color(0xFFF59E0B).withOpacity(0.10),
                    const Color(0xFFF59E0B).withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),

          // ── Main scrollable content ──
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        // ── Logo with elastic bounce ──
                        AnimatedBuilder(
                          animation: _logoBounce,
                          builder: (BuildContext context, Widget? child) {
                            return Transform.scale(
                              scale: _logoBounce.value.clamp(0.0, 1.2),
                              child: child,
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: scheme.primary.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.eco_rounded,
                              size: 52,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'FridgeGuardian',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: titleColor,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _isLogin ? 'Welcome back!' : 'Create your account',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: const Color(0xFF1E293B),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),

                        // ── Frosted glass form card with spring physics ──
                        SlideTransition(
                          position: _springSlide,
                          child: ScaleTransition(
                            scale: _springScale,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: BackdropFilter(
                                filter: ui.ImageFilter.blur(
                                    sigmaX: 20, sigmaY: 20),
                                child: Container(
                                  padding: const EdgeInsets.all(28),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.7),
                                      width: 1.5,
                                    ),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.06),
                                        blurRadius: 32,
                                        offset: const Offset(0, 12),
                                      ),
                                    ],
                                  ),
                                  child: Form(
                                    key: _formKey,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        // display name (register only)
                                        if (!_isLogin) ...<Widget>[
                                          TextFormField(
                                            controller:
                                                _displayNameController,
                                            textInputAction:
                                                TextInputAction.next,
                                            style: TextStyle(
                                              color: titleColor,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            decoration: _inputDecoration(
                                              label: 'Display Name (optional)',
                                              icon: Icons.person_outline,
                                              labelColor: labelColor,
                                              hintColor: hintColor,
                                            ),
                                          ),
                                          const SizedBox(height: 18),
                                        ],

                                        // email
                                        TextFormField(
                                          controller: _emailController,
                                          keyboardType:
                                              TextInputType.emailAddress,
                                          textInputAction:
                                              TextInputAction.next,
                                          style: TextStyle(
                                            color: titleColor,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          decoration: _inputDecoration(
                                            label: 'Email',
                                            icon: Icons.email_outlined,
                                            labelColor: labelColor,
                                            hintColor: hintColor,
                                          ),
                                          validator: (String? value) {
                                            if (value == null ||
                                                value.trim().isEmpty) {
                                              return 'Please enter your email';
                                            }
                                            if (!value.contains('@')) {
                                              return 'Please enter a valid email';
                                            }
                                            return null;
                                          },
                                        ),
                                        const SizedBox(height: 18),

                                        // password
                                        TextFormField(
                                          controller: _passwordController,
                                          obscureText: _obscurePassword,
                                          textInputAction: _isLogin
                                              ? TextInputAction.done
                                              : TextInputAction.next,
                                          style: TextStyle(
                                            color: titleColor,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          decoration: _inputDecoration(
                                            label: 'Password',
                                            icon: Icons.lock_outline,
                                            labelColor: labelColor,
                                            hintColor: hintColor,
                                            suffix: IconButton(
                                              icon: Icon(
                                                _obscurePassword
                                                    ? Icons.visibility_off_outlined
                                                    : Icons.visibility_outlined,
                                                color: hintColor,
                                                size: 20,
                                              ),
                                              onPressed: () => setState(() =>
                                                  _obscurePassword =
                                                      !_obscurePassword),
                                            ),
                                          ),
                                          validator: (String? value) {
                                            if (value == null ||
                                                value.isEmpty) {
                                              return 'Please enter your password';
                                            }
                                            if (value.length < 6) {
                                              return 'Password must be at least 6 characters';
                                            }
                                            return null;
                                          },
                                        ),

                                        // confirm password (register only)
                                        if (!_isLogin) ...<Widget>[
                                          const SizedBox(height: 18),
                                          TextFormField(
                                            controller:
                                                _confirmPasswordController,
                                            obscureText: _obscureConfirm,
                                            textInputAction:
                                                TextInputAction.done,
                                            style: TextStyle(
                                              color: titleColor,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            decoration: _inputDecoration(
                                              label: 'Confirm Password',
                                              icon: Icons.lock_outline,
                                              labelColor: labelColor,
                                              hintColor: hintColor,
                                              suffix: IconButton(
                                                icon: Icon(
                                                  _obscureConfirm
                                                      ? Icons.visibility_off_outlined
                                                      : Icons.visibility_outlined,
                                                  color: hintColor,
                                                  size: 20,
                                                ),
                                                onPressed: () => setState(
                                                    () => _obscureConfirm =
                                                        !_obscureConfirm),
                                              ),
                                            ),
                                            validator: (String? value) {
                                              if (value !=
                                                  _passwordController.text) {
                                                return 'Passwords do not match';
                                              }
                                              return null;
                                            },
                                          ),
                                        ],

                                        // error message
                                        if (_errorMessage != null) ...<Widget>[
                                          const SizedBox(height: 18),
                                          Container(
                                            padding: const EdgeInsets.all(14),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFEE2E2),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: const Color(0xFFFECACA),
                                              ),
                                            ),
                                            child: Row(
                                              children: <Widget>[
                                                const Icon(
                                                  Icons.error_outline,
                                                  color: Color(0xFFDC2626),
                                                  size: 20,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    _errorMessage!,
                                                    style: const TextStyle(
                                                      color: Color(0xFF991B1B),
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],

                                        const SizedBox(height: 26),

                                        // submit button with spring press
                                        _SpringPressButton(
                                          onPressed:
                                              _loading ? null : _submit,
                                          child: Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 16),
                                            decoration: BoxDecoration(
                                              gradient: const LinearGradient(
                                                colors: <Color>[
                                                  Color(0xFF0EA5E9),
                                                  Color(0xFF06B6D4),
                                                ],
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              boxShadow: <BoxShadow>[
                                                BoxShadow(
                                                  color: const Color(0xFF0EA5E9)
                                                      .withOpacity(0.35),
                                                  blurRadius: 16,
                                                  offset: const Offset(0, 6),
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: _loading
                                                  ? const SizedBox(
                                                      width: 22,
                                                      height: 22,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2.5,
                                                        color: Colors.white,
                                                      ),
                                                    )
                                                  : Text(
                                                      _isLogin
                                                          ? 'Sign In'
                                                          : 'Create Account',
                                                      style: const TextStyle(
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: Colors.white,
                                                        letterSpacing: 0.3,
                                                      ),
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),

                        // toggle login / register
                        TextButton(
                          onPressed: _loading ? null : _toggleMode,
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.5),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Text(
                            _isLogin
                                ? "Don't have an account? Register"
                                : 'Already have an account? Sign In',
                            style: const TextStyle(
                              color: Color(0xFF0369A1),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // divider
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Divider(
                                color: const Color(0xFF64748B).withOpacity(0.4),
                                thickness: 1.2,
                              ),
                            ),
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 14),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.55),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text(
                                'OR',
                                style: TextStyle(
                                  color: Color(0xFF334155),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: const Color(0xFF64748B).withOpacity(0.4),
                                thickness: 1.2,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 8),

                        // guest / anonymous with spring press
                        _SpringPressButton(
                          onPressed: _loading ? null : _continueAsGuest,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.65),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.8),
                                    width: 1.5,
                                  ),
                                  boxShadow: <BoxShadow>[
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.04),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    const Icon(Icons.person_outline,
                                        color: Color(0xFF0369A1), size: 20),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Continue as Guest',
                                      style: TextStyle(
                                        color: Color(0xFF0369A1),
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
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
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Consistent input decoration with explicit dark-on-light colors
  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    required Color labelColor,
    required Color hintColor,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: labelColor,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      hintStyle: TextStyle(color: hintColor),
      prefixIcon: Icon(icon, color: const Color(0xFF64748B), size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white.withOpacity(0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.6)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF0EA5E9), width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFEF4444)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.8),
      ),
      errorStyle: const TextStyle(
        color: Color(0xFFDC2626),
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Framer Motion–style spring damping curve ────────────────────────────
// Uses flutter/physics SpringSimulation to create real mass-spring-damper
// physics: stiffness controls bounce speed, damping controls oscillation.
// ═══════════════════════════════════════════════════════════════════════════

class _SpringDampingCurve extends Curve {
  const _SpringDampingCurve({
    this.mass = 1.0,
    this.stiffness = 180.0,
    this.damping = 14.0,
  });

  final double mass;
  final double stiffness;
  final double damping;

  @override
  double transformInternal(double t) {
    final SpringSimulation simulation = SpringSimulation(
      SpringDescription(mass: mass, stiffness: stiffness, damping: damping),
      0.0, // start
      1.0, // end
      0.0, // initial velocity
    );
    return simulation.x(t);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ── Button with spring-press physics feedback ───────────────────────────
// On tap-down it springs to 0.95 scale, on release it springs back to 1.0.
// This gives a satisfying Framer Motion–style "squish" feel.
// ═══════════════════════════════════════════════════════════════════════════

class _SpringPressButton extends StatefulWidget {
  const _SpringPressButton({
    required this.child,
    this.onPressed,
  });

  final Widget child;
  final VoidCallback? onPressed;

  @override
  State<_SpringPressButton> createState() => _SpringPressButtonState();
}

class _SpringPressButtonState extends State<_SpringPressButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    _scale = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const _SpringDampingCurve(stiffness: 300, damping: 15),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _controller.forward();
  }

  void _onTapUp(TapUpDetails _) {
    _controller.reverse();
    widget.onPressed?.call();
  }

  void _onTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onPressed != null ? _onTapDown : null,
      onTapUp: widget.onPressed != null ? _onTapUp : null,
      onTapCancel: widget.onPressed != null ? _onTapCancel : null,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (BuildContext context, Widget? child) {
          return Transform.scale(
            scale: _scale.value,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
