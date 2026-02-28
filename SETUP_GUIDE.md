# FridgeGuardian — Complete Setup Guide

> **Cross-Platform**: FridgeGuardian runs as a **native mobile app** (Android/iOS) and a **responsive web application** accessible from any browser — all from a single Flutter codebase.

---

## Prerequisites

| Tool | Required Version | How to Install |
|------|-----------------|---------------|
| **Flutter SDK** | 3.41.2+ (stable) | https://docs.flutter.dev/get-started/install |
| **Dart SDK** | 3.11.0+ (bundled with Flutter) | Comes with Flutter |
| **Git** | Any recent version | https://git-scm.com/downloads |
| **Chrome** | Any recent version | For web version |
| **Android Studio** | Latest (for Android SDK + emulator) | https://developer.android.com/studio |
| **VS Code** *(recommended)* | Latest | With Flutter & Dart extensions |

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/Gohpeijia/KitaHack2026.git
cd KitaHack2026/flutter_application_1
```

---

## Step 2: Create the `.env` File

The `.env` file is **gitignored** for security and must be created manually.

Inside the `flutter_application_1/` folder (same level as `pubspec.yaml`), create a file named `.env`:

```env
GEMINI_API_KEY="YOUR_GEMINI_API_KEY_HERE"
GEMINI_MODEL="gemini-2.5-flash-lite"
```

### How to get a Gemini API key (free):
1. Go to https://aistudio.google.com/apikey
2. Sign in with a Google account
3. Click **"Create API key"**
4. Copy the key and paste it into the `.env` file

> **Important:** The `.env` file is loaded as a Flutter asset (listed in `pubspec.yaml` under `assets:`). It must be at the root of `flutter_application_1/` — do NOT put it in a subfolder.

---

## Step 3: Install Dependencies

```bash
flutter pub get
```

This installs all packages:

| Package | Purpose |
|---------|---------|
| `google_generative_ai` | Gemini AI SDK (image analysis, barcode lookup, nudge generation) |
| `firebase_core` | Firebase initialization |
| `cloud_firestore` | Real-time NoSQL database for inventory & user profiles |
| `firebase_auth` | Email/password + anonymous guest authentication |
| `firebase_storage` | Fridge scan image uploads |
| `firebase_messaging` | FCM push notifications |
| `flutter_local_notifications` | Scheduled local expiry reminders (mobile) |
| `timezone` / `flutter_timezone` | Timezone-aware notification scheduling |
| `mobile_scanner` | Barcode scanning via device camera (mobile) |
| `image_picker` | Camera / gallery image selection |
| `flutter_dotenv` | Secure environment variable loading |

---

## Step 4: Verify Flutter Setup

```bash
flutter doctor
```

Ensure there are no critical errors for your target platform (Web, Android, or Windows).

---

## Running the App

### Option A: Web (Chrome) — Works on Any Desktop

```bash
flutter run -d chrome
```

Opens FridgeGuardian in Chrome. **All features work on web** including:
- Fridge image scanning (upload from gallery)
- AI analysis via Gemini
- Inventory management, suggestions, dashboard
- Firebase Auth (email/password + guest login)
- Cloud Firestore real-time sync
- FCM push notifications (via service worker)
- In-app notification overlays for expiry alerts
- Smart Grocery List with buy-less warnings

> **Note:** Barcode scanning requires native camera access and is **mobile-only**. On web, it falls back to demo mode.

---

### Option B: Android Phone (Full Feature Set)

**Requirements:**
- Android phone with USB debugging enabled
- USB cable connected to PC

**Steps:**

1. **Enable Developer Options** on your phone:
   - Settings → About Phone → tap **"Build Number"** 7 times

2. **Enable USB Debugging**:
   - Settings → Developer Options → USB Debugging → **ON**

3. **Connect phone via USB** and accept the debugging prompt on phone

4. **Verify device is detected:**
   ```bash
   flutter devices
   ```
   You should see your device listed (e.g., `Honor 200 Pro (mobile) • AE6RUT4611040768`)

5. **Run the app:**
   ```bash
   flutter run -d <DEVICE_ID>
   ```
   Or if only one device is connected:
   ```bash
   flutter run -d android
   ```

**All features work on Android** including:
- ✅ Real-time barcode scanning with camera (torch toggle + camera switch)
- ✅ Fridge photo scanning (camera or gallery)
- ✅ Native push notifications + local scheduled reminders at 9 AM
- ✅ Everything from the web version

> After the app is installed on your phone, it **runs independently** — you can unplug the USB cable.

---

### Option C: Android Emulator

```bash
# List available emulators
flutter emulators

# Launch an emulator
flutter emulators --launch <emulator_name>

# Run the app
flutter run -d android
```

> **Note:** Camera/barcode features require a physical device. Emulator runs everything else.

---

### Option D: Windows Desktop App

```bash
flutter run -d windows
```

Same features as the web version. Firebase, Gemini AI, and notifications all work. Barcode scanning is not available on desktop.

---

### Option E: iOS (macOS only)

Requires a Mac with Xcode installed.

```bash
# Open iOS simulator
open -a Simulator

# Run
flutter run -d ios
```

> **Note:** The `ios/Runner/GoogleService-Info.plist` file is **not included** in the repo. You need to download it from the [Firebase Console](https://console.firebase.google.com/) → Project Settings → iOS app → download `GoogleService-Info.plist` → place it in `ios/Runner/`.

---

## Firebase Project Info

The app is pre-configured to use an existing Firebase project. **No additional Firebase setup is needed** — just create the `.env` file and run.

| Setting | Value |
|---------|-------|
| **Project ID** | `kitahack2026-c2a42` |
| **Auth Domain** | `kitahack2026-c2a42.firebaseapp.com` |
| **Storage Bucket** | `kitahack2026-c2a42.firebasestorage.app` |
| **Plan** | Spark (Free) |

### Firebase configuration files (already in repo):
- `lib/firebase_options.dart` — Platform-specific Firebase config (auto-generated by FlutterFire CLI)
- `android/app/google-services.json` — Android Firebase config
- `web/firebase-messaging-sw.js` — Web push notification service worker

### Firebase services used:
| Service | Purpose |
|---------|---------|
| **Authentication** | Email/password registration + anonymous guest login |
| **Cloud Firestore** | Inventory storage, user profiles, FCM device tokens |
| **Firebase Storage** | Fridge scan image uploads |
| **Firebase Cloud Messaging** | Push notifications across all platforms |

### Firestore Security Rules:
```
Users can only read/write their own data (request.auth.uid == userId)
```

---

## Project Structure

```
KitaHack2026/
├── flutter_application_1/              ← Main app code
│   ├── lib/
│   │   ├── main.dart                   ← Entry point (Firebase init + dotenv load)
│   │   ├── firebase_options.dart       ← Firebase config (all platforms)
│   │   ├── ui/
│   │   │   ├── fridgeguardian_demo.dart    ← Main app (all screens + logic)
│   │   │   └── auth_screen.dart            ← Login / register screen
│   │   └── service/
│   │       ├── gemini_service.dart         ← Gemini AI with 4-model rotation
│   │       └── impact_aggregator.dart      ← CO2 impact calculation
│   ├── .env                            ← API keys (NOT in repo — create manually)
│   ├── .env.example                    ← Template for .env
│   ├── pubspec.yaml                    ← Dependencies
│   ├── web/
│   │   ├── index.html                  ← Web entry point + FCM setup
│   │   └── firebase-messaging-sw.js    ← Background push notification handler
│   └── android/
│       └── app/
│           ├── google-services.json         ← Firebase Android config
│           └── src/main/AndroidManifest.xml ← Permissions (Camera, Notifications)
├── dataconnect/                        ← Firebase Data Connect config
├── firestore.rules                     ← Firestore security rules
├── firestore.indexes.json              ← Firestore indexes
└── README.md
```

---

## Feature Availability by Platform

| Feature | Web (Chrome) | Android | Windows | iOS | 
|---------|:---:|:---:|:---:|:---:|
| Fridge Image Scan (AI) | ✅ Gallery | ✅ Camera + Gallery | ✅ Gallery | ✅ Camera + Gallery |
| Barcode Scanning | ❌ Demo only | ✅ Real camera | ❌ | ✅ Real camera |
| AI Inventory Analysis (Gemini) | ✅ | ✅ | ✅ | ✅ |
| Firebase Auth (Email + Guest) | ✅ | ✅ | ✅ | ✅ |
| Cloud Firestore Sync | ✅ | ✅ | ✅ | ✅ |
| Push Notifications (FCM) | ✅ | ✅ | ✅ | ✅ |
| Local Scheduled Reminders (9AM) | ❌ | ✅ | ❌ | ✅ |
| In-App Notification Overlay | ✅ | ✅ | ✅ | ✅ |
| Smart Grocery List | ✅ | ✅ | ✅ | ✅ |
| Dashboard & KPIs | ✅ | ✅ | ✅ | ✅ |
| Demo Mode (Offline) | ✅ | ✅ | ✅ | ✅ |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `flutter pub get` fails | Run `flutter clean` then `flutter pub get` |
| `.env` not loading / API key error | Ensure `.env` is in `flutter_application_1/` root (same level as `pubspec.yaml`) and contains `GEMINI_API_KEY="your-key"` |
| Firebase auth fails | The Firebase project must have **Email/Password** and **Anonymous** sign-in enabled in the [Firebase Console](https://console.firebase.google.com/) → Authentication → Sign-in method |
| Android build fails | Run `flutter doctor` and fix Android toolchain issues. Ensure **Java 17+** is installed. |
| Barcode scanner doesn't open (web) | Barcode scanning is **mobile-only**. On web it adds a demo item instead. |
| "Gemini quota exceeded" | The free tier allows ~20 requests/day per model. The app auto-rotates through **4 Gemini models** (~80 requests/day total). Wait for the countdown timer or try again later. |
| Notifications not working (web) | Allow notification permissions in browser when prompted. Verify `web/firebase-messaging-sw.js` exists. |
| Phone not detected | Enable USB debugging, try a different USB cable, or run `adb devices` to verify connection. |
| iOS missing `GoogleService-Info.plist` | Download from Firebase Console → Project Settings → iOS app → place in `ios/Runner/` |

---

## Quick Start (TL;DR)

```bash
# 1. Clone
git clone https://github.com/Gohpeijia/KitaHack2026.git
cd KitaHack2026/flutter_application_1

# 2. Create .env file with your Gemini API key
echo 'GEMINI_API_KEY="your-key-here"' > .env

# 3. Install dependencies
flutter pub get

# 4. Run on web
flutter run -d chrome

# 4. OR run on Android phone
flutter run -d android
```
