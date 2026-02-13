import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

void main() {
  runApp(const MyApp());
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
      home: const TutorPage(),
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

  // ⚠️ API KEY: Paste your "AIza..." key here!
  final String _apiKey = 'AIzaSyAjUGfZAkIB_a7VYX35eqE0ECB4l1h8iuw';

  Future<void> _getFeedback() async {
    if (_scoreController.text.isEmpty) return;

    setState(() {
      _isLoading = true;
      _feedback = "Thinking...";
    });

    try {
      // 1. Setup the Model
      final model = GenerativeModel(
        model: 'gemini-1.5-flash',
        apiKey: _apiKey,
      );

      // 2. Create the Prompt
      final prompt = "The student got a score of ${_scoreController.text}/100. "
          "You are a friendly teacher. Give them 2 sentences of encouraging feedback.";

      // 3. Generate Content
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
      body: Padding(
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
          ],
        ),
      ),
    );
  }
}