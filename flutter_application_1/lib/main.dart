import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // load environment variables from .env file
import 'package:firebase_core/firebase_core.dart'; 
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'ui/fridgeguardian_demo.dart' show FridgeGuardianApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // initialize Firebase before running the app
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // load the .env file
  await dotenv.load(fileName: ".env"); 
  
  runApp(const FridgeGuardianApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Tutor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const FridgeGuardianApp(),
    );
  }
}

class TutorPage extends StatefulWidget {
  const TutorPage({super.key});

  @override
  State<TutorPage> createState() => _TutorPageState();
}

class _TutorPageState extends State<TutorPage> {
  // CONTROL: Controller to read the text box
  final TextEditingController _scoreController = TextEditingController();
  
  // STATE: This holds the AI's response
  String _feedback = "Enter a score to get feedback!";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loginTestUser();
  }

  // 👇 logic
  Future<void> _loginTestUser() async {
    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: "kitahacktest@gmail.com", // change to the email you set in firebase console
        password: "Hack1234",          // change to the password you set for that test account
      );
      debugPrint("✅ Test account login successful UID: ${credential.user?.uid}");
    } on FirebaseAuthException catch (e) {
      debugPrint("❌ Test version login failed: ${e.code}");
    }
  }

  Future<void> _getFeedback() async {
    if (_scoreController.text.isEmpty) return;

    setState(() {
      _isLoading = true;
      _feedback = "Thinking...";
    });

    try {
      // read the API key from the environment variable
      final apiKey = dotenv.env['GEMINI_API_KEY'];
      
      // check is it read successfully
      if (apiKey == null || apiKey.isEmpty) {
        setState(() {
          _feedback = "Error: cant find the API key in environment variables.";
          _isLoading = false;
        });
        return;
      }

      // 4. Setup the Model using the secure key
      final model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: apiKey, 
      );

      // 5. Create the Prompt
      final prompt = "The student got a score of ${_scoreController.text}/100. "
          "You are a friendly teacher. Give them 2 sentences of encouraging feedback.";

      // 6. Generate Content
      final response = await model.generateContent([Content.text(prompt)]);

      setState(() {
        _feedback = response.text ?? "No response from AI.";
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _feedback = "Error: $e";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("AI Grading Tutor")),
      body: SingleChildScrollView( // added to prevent overflow when keyboard appears
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Input Field
              TextField(
                controller: _scoreController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Enter Student Score (0-100)',
                ),
              ),
              const SizedBox(height: 20),

              // The Button
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _getFeedback,
                icon: _isLoading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
                    : const Icon(Icons.smart_toy),
                label: Text(_isLoading ? "Asking Gemini..." : "Get AI Feedback"),
              ),
              const SizedBox(height: 30),

              // The Result
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.deepPurple.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.deepPurple.shade200),
                ),
                child: Text(
                  _feedback,
                  style: const TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
              
              const SizedBox(height: 50), 

              // Push Notification Test Button
              ElevatedButton(
                onPressed: () async {
                  try {
                    // 1. request permission for push notifications (this will show a prompt to the user)
                    await FirebaseMessaging.instance.requestPermission();

                    // 2. catch Token
                    String? token = await FirebaseMessaging.instance.getToken();

                    if (token != null) {
                      debugPrint("✅ catch token: $token");

                      final String userId = FirebaseAuth.instance.currentUser?.uid ?? 'test_user_001';
                      // 3. Save token to Firestore
                      await FirebaseFirestore.instance.collection('users').doc(userId).set({
                        'fcm_token': token,
                        'name': 'Demo User', 
                      }, SetOptions(merge: true));

                      debugPrint("✅ Test Token has been forcibly written to Firestore! Check the console!");
                      
                      // if you want to show a confirmation in the app, you can use a SnackBar or Dialog here
                      if(context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                           const SnackBar(content: Text('✅ Token uploaded to Firestore! Check console for details.'))
                        );
                      }
                    }
                  } catch (e) {
                    debugPrint("❌ Error uploading token: $e");
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange, // button color
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)
                ),
                child: const Text('Test Push Notification Setup'),
              ),

              const SizedBox(height: 20), // Add some spacing

              // 🌟 NEW: Carbon Reduction Test Button 🌟
              ElevatedButton(
                onPressed: () async {
                  // 1. Instantiate the class you wrote
                  final aggregator = ImpactAggregator();
                  
                  // 2. Generate a random ID for test food to ensure a reaction on every click
                  final testFoodId = 'food_${DateTime.now().millisecondsSinceEpoch}';
                  final String userId = FirebaseAuth.instance.currentUser?.uid ?? 'test_user_001';
                  
                  // 3. Call the function (Simulate consuming 0.5kg of food)
                  await aggregator.markFoodAsSaved(testFoodId, userId, 0.5);
                  
                  // 4. Show success popup
                  if(context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                       const SnackBar(
                         content: Text('🌱 Success! Consumed 0.5kg of food, carbon points added! Check Firebase!'),
                         backgroundColor: Colors.green,
                       )
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green, // Eco-friendly color
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)
                ),
                child: const Text('Mark as Consumed (Test Carbon Impact)'),
              ),

            ],
          ),
        ),
      ),
    );
  }
}

// 🌟 NEW: Carbon Reduction Aggregation Logic Class (At the bottom of the file) 🌟
class ImpactAggregator {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Mark food as consumed/donated and synchronously calculate carbon reduction
  Future<void> markFoodAsSaved(String inventoryId, String userId, double weightKg) async {
    try {
      debugPrint("📊 Calculating environmental impact...");

      // 1. Calculate the carbon emission saved this time
      const double emissionFactor = 2.5; 
      final double co2Saved = weightKg * emissionFactor;

      // 2. Create a WriteBatch (bulk write operation)
      WriteBatch batch = _firestore.batch();

      // Action A: Update the status of this food item to 'consumed'
      DocumentReference itemRef = _firestore
        .collection('users')
        .doc(userId)
        .collection('inventory')
        .doc(inventoryId);
      // Note: Using set with merge: true so that even if this test ID doesn't exist, it will auto-create and write the status
      batch.set(itemRef, {'status': 'consumed'}, SetOptions(merge: true));

      // Action B: Safely accumulate total carbon reduction in the user profile
      DocumentReference userRef = _firestore.collection('users').doc(userId);
      batch.set(userRef, {
        'total_co2_saved': FieldValue.increment(co2Saved)
      }, SetOptions(merge: true)); 

      // 3. Commit both actions at once
      await batch.commit();

      debugPrint("🌍 Success! Reduced carbon emission by $co2Saved kg this time!");

    } catch (e) {
      debugPrint("❌ Calculation failed: $e");
    }
  }
}

