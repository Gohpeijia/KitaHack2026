<img width="720" height="560" alt="Gemini_Generated_Image_icn728icn728icn7 (2)" src="https://github.com/user-attachments/assets/07b85c41-f058-469c-94d3-950ce8315940" />


# 🍃 FridgeGuardian

_**KitaHack 2026 Submission**_ | A smart, zero-waste fridge management system powered by Gemini 2.5 Flash and Firebase.
  
## 🎯 The Mission

In Malaysia, thousands of tonnes of food are wasted daily. FridgeGuardian is designed to tackle **SDG 12 (Responsible Consumption and Production)** and **SDG 13 (Climate Action)**.

Unlike traditional inventory apps that rely on manual data entry, FridgeGuardian uses computer vision to track your food and acts as a behavioral intervention tool to gently "nudge" users away from over-purchasing.

## 📱 App Preview

| 😃 1. The Login Page | 📸 2. The Home Page | 📸 3. Smart Vision Scan | 🧠 4. Behavioral Insights | 🚨 5. The Nudge Engine |
| :---: | :---: | :---: | :---: |:---: |
| <img width="100" height="180" alt="{89FEE5FC-4EBE-4C01-94E2-88FF13F7DFFB}" src="https://github.com/user-attachments/assets/557ad4b8-1d82-4f65-8728-b97937cf7f56" /> |\ <img width="180" height="120" src="https://github.com/user-attachments/assets/0eaef85f-e098-4370-8556-ab3df4ae9141"/> | <img width="180" height="120" src="https://github.com/user-attachments/assets/c7f3a323-166d-49c4-9394-c4936be83648" /> | <img width="180" height="120" src= "https://github.com/user-attachments/assets/f056b7ca-cb7f-4d26-9490-36b7973d9bba"> | <img width="200" height="120" src= "https://github.com/user-attachments/assets/65f5d752-65f4-4274-b506-5946c1adfb9e"> |
||<img width="287.5" height="640" alt="image" src="https://github.com/user-attachments/assets/6d05fab6-f823-4d1e-9d92-0e3cb9a6a2fa" /> | <img width="287.5" height="640" alt="image" src="https://github.com/user-attachments/assets/6a0987f6-c713-4843-b40b-563cc07727f4" /> | <img width="280" height="550" alt="image" src="https://github.com/user-attachments/assets/c388f434-3c7b-4a23-8826-9c7262ba9fd1" /> | <img width="240" height="500" alt="image" src="https://github.com/user-attachments/assets/c77cc3db-2a3f-454d-aec1-95deec24a435" /> |
| *Login Design. User can sign in or continue as guest to use the app.* | *Homepage Design. The overall record are appear here.* |*Fridge Scan Design. No manual typing or data entry required.* | *AI automatically extracts expiry dates and analyzes your waste patterns.* | *The AI sates the ways to handle food, user can press the comsumed button to notice the CO_2 emissions saved* |

## ✨ Key Features (The USP)

**📸 Vision-Powered Logging:** Snap a picture of your fridge. The AI automatically extracts food items, quantities, and estimates expiry dates.

**🧠 Behavioral Nudges:** The AI analyzes your storage patterns and provides actionable advice (e.g., "You frequently leave 1L milk unfinished. Consider buying the 500ml carton next time.").

**🌍 Carbon Impact Tracker:** Automatically calculates the $CO_2$ emissions saved when food is successfully consumed or shared rather than thrown away.

**🤝 Community Bridge:** Flags surplus items that are unlikely to be finished, suggesting them for community donation before they expire.


## 🏗️ Tech Stack & $0 Architecture
<img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" />
<img src="https://img.shields.io/badge/Gemini_AI-8E75B2?style=for-the-badge&logo=google&logoColor=white" />
<img src="https://img.shields.io/badge/Firebase-FFCA28?style=for-the-badge&logo=firebase&logoColor=black" />
To ensure maximum accessibility and maintain a strict **$0 budget**, this project is built on a highly efficient, serverless architecture:

- **Frontend:** Flutter (Dart)
- **AI Engine:** Google Gemini 2.5 Flash API (Free Tier)
- **Database & Auth:** Firebase Cloud Firestore & Firebase Auth (Spark Plan)

## ⚙️ System Architecture

To keep our solution highly scalable and completely free ($0), we decoupled the AI processing from standard Cloud Functions:

```mermaid
graph TD
    A[Flutter App] -->|1. Takes Photo| B(Image Compression)
    B -->|2. Sends Image & Prompt| C{Gemini 2.5 Flash API}
    C -->|3. Returns JSON| A
    A -->|4. Writes Data| D[(Firebase Firestore)]
    E[Python Nudge Engine] -->|5. Daily CRON scan| D
    E -->|6. Triggers Alert| F((Firebase Cloud Messaging))
    F -->|7. Sends Push Nudge| A
```

Architecture Note: To avoid the mandatory billing requirements of Cloud Functions, the AI orchestration is securely handled within the Flutter application. The client processes the image, retrieves the structured JSON from Gemini, and performs batch writes directly to Firestore using secure security rules.

## 🚀 Getting Started (Local Setup)

Follow these steps to run the project locally.

**1. Prerequisites**
- [Flutter SDK](https://docs.flutter.dev/install) installed.
- A Firebase project (Spark plan is sufficient).
- A [Google Gemini API Key](https://aistudio.google.com/app/api-keys).

**2. Clone the Repository:**

In Bash:

    git clone https://github.com/your-username/kitahack2026.git \
    cd kitahack2026/flutter_application_1

**3. Environment Setup (Crucial)**
 
   You must provide your own Gemini API key. Create a `.env` file in the root directory of the Flutter project `(flutter_application_1/.env)` and add your key:

    # Do not commit this file to version control!
    GEMINI_API_KEY=your_actual_api_key_here

**4. Firebase Configuration**
   1. Register your Android/iOS app in your Firebase Console.
 
   2. Download the `google-services.json` (for Android) and place it in `android/app/`.
 
   3. Ensure **Firestore and Email/Password Authentication** are enabled in your Firebase Console.

**5. Run the App** 

In Bash:

    flutter pub get
    flutter run

## 🛠️ How We Built It & Challenges Overcome
* **AI Vision Latency:** Initially, sending raw phone images to Gemini took over 20 seconds. We built a pre-processing layer in Flutter to compress images, reducing AI inference time to under 4 seconds without losing vision quality.
* **The Zombie Food Bug:** We had to write complex compound queries in Firestore to ensure our Python Nudge Engine only alerted users about food that was *expiring* AND still marked as *active* (not yet consumed).

## 🔐 Security Notes
  
  - **API Keys:** The `.env` file is included in `.gitignore` to prevent accidental credential leaks.
  
  - **Database:** Firestore is protected by strict Security Rules ensuring users can only read and write to their own isolated `inventory` collections based on their `uid`.

#### Built with ❤️ for KitaHack 2026
## 👨‍💻 The Team
* **[Looi Yu Zhi]** - [Team Leader & Idea provider & Documentation Lead] 
* **[Vincent Loh Yong Sheng]** - [Frontend (FLutter) Lead] 
* **[Goh Pei Jia]** - [Backend (Firebase & Gemini API) & GitHub Lead]
* **[Daniel Goh Zhi Qian]** - [AI Lead]
