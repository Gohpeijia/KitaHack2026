import 'package:flutter/material.dart';
// 1. Add this import for the AI
import 'package:google_generative_ai/google_generative_ai.dart'; 
// 2. Add this import to get your secret key
import 'api_key.dart'; 

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Assistant',
      theme: ThemeData(
        // Using a Blue theme instead of Deep Purple
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      // 3. We changed "MyHomePage" to "ChatScreen"
      home: const ChatScreen(), 
    );
  }
}

// We deleted the "MyHomePage" class (the counter) and added this ChatScreen instead.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final GenerativeModel _model;
  
  // This list will store the chat history
  final List<String> _chatHistory = []; 
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Initialize the Gemini Model with your API key
    _model = GenerativeModel(model: 'gemini-pro', apiKey: apiKey);
  }

  Future<void> _sendMessage() async {
    final message = _controller.text;
    if (message.isEmpty) return;

    setState(() {
      _isLoading = true;
      // Add user message to history
      _chatHistory.add("You: $message"); 
      _controller.clear();
    });

    try {
      final content = [Content.text(message)];
      final response = await _model.generateContent(content);

      setState(() {
        // Add AI response to history
        _chatHistory.add("AI: ${response.text ?? 'No response'}");
      });
    } catch (e) {
      setState(() {
        _chatHistory.add("Error: $e");
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("My AI Assistant"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // This Expanded widget displays the list of messages
          Expanded(
            child: ListView.builder(
              itemCount: _chatHistory.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    _chatHistory[index],
                    style: const TextStyle(fontSize: 16),
                  ),
                );
              },
            ),
          ),
          if (_isLoading) const LinearProgressIndicator(),
          
          // Input area
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: "Ask something...",
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}