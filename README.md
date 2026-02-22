🍃 FridgeGuardian

KitaHack 2026 Submission | A smart, zero-waste fridge management system powered by Gemini 2.5 Flash and Firebase.


🎯 The Mission

In Malaysia, thousands of tonnes of food are wasted daily. FridgeGuardian is designed to tackle SDG 12 (Responsible Consumption and Production) and SDG 13 (Climate Action).

Unlike traditional inventory apps that rely on manual data entry, FridgeGuardian uses computer vision to track your food and acts as a behavioral intervention tool to gently "nudge" users away from over-purchasing.


✨ Key Features (The USP)📸

**Vision-Powered Logging:** Snap a picture of your fridge. The AI automatically extracts food items, quantities, and estimates expiry dates.

**🧠 Behavioral Nudges:** The AI analyzes your storage patterns and provides actionable advice (e.g., "You frequently leave 1L milk unfinished. Consider buying the 500ml carton next time.").

**🌍 Carbon Impact Tracker:** Automatically calculates the $CO_2$ emissions saved when food is successfully consumed or shared rather than thrown away.

**🤝 Community Bridge:** Flags surplus items that are unlikely to be finished, suggesting them for community donation before they expire.


**🏗️ Tech Stack & $0 Architecture**
To ensure maximum accessibility and maintain a strict $0 budget, this project is built on a highly efficient, serverless architecture:

**Frontend:** Flutter (Dart)

**AI Engine:** Google Gemini 2.5 Flash API (Free Tier)

**Database & Auth:** Firebase Cloud Firestore & Firebase Auth (Spark Plan)Architecture 
Note: To avoid the mandatory billing requirements of Cloud Functions, the AI orchestration is securely handled within the Flutter application. The client processes the image, retrieves the structured JSON from Gemini, and performs batch writes directly to Firestore using secure security rules.



**🚀 Getting Started (Local Setup)**

Follow these steps to run the project locally.

1. Prerequisites
   Flutter SDK installed.

    A Firebase project (Spark plan is sufficient).
 
   A Google Gemini API Key.

3. Clone the Repository(in Bash):
   git clone https://github.com/your-username/kitahack2026.git

   cd kitahack2026/flutter_application_1

4. Environment Setup (Crucial)
 
   You must provide your own Gemini API key. Create a .env file in the root directory of the Flutter project (flutter_application_1/.env) and add your key:

   Do not commit this file to version control!
 
   GEMINI_API_KEY=your_actual_api_key_here

5. Firebase Configuration
   Register your Android/iOS app in your Firebase Console.
 
   Download the google-services.json (for Android) and place it in android/app/.
 
   Ensure Firestore and Email/Password Authentication are enabled in your Firebase Console.

6. Run the App (Bash)

   flutter pub get

   flutter run


**🔐 Security Notes**
  
   API Keys: The .env file is included in .gitignore to prevent accidental credential leaks.
  
   Database: Firestore is protected by strict Security Rules ensuring users can only read and write to their own isolated inventory collections based on their uid.

Built with ❤️ for KitaHack 2026
