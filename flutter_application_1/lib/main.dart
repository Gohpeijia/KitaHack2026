import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // load environment variables from .env file
import 'package:firebase_core/firebase_core.dart'; 
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // initialize Firebase before running the app
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // load the .env file
  await dotenv.load(fileName: ".env"); 
  
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

  @override
  void initState() {
    super.initState();
    _loginTestUser();
  }

  // 👇 logic
  Future<void> _loginTestUser() async {
    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: "kitahacktest@gmail.com", // chenge to the email you set in firebase console
        password: "Hack1234",         // change to the password you set for that test account
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
      body: SingleChildScrollView( // 添加了滑动视图，防止小屏幕手机内容溢出
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
              
              const SizedBox(height: 50), // 加大一点间距，和上方功能区分开

              // 👇 新添加的测试按钮放在这里 👇
              ElevatedButton(
                onPressed: () async {
                  try {
                    // 1. 请求系统推送权限 (弹窗问用户同不同意)
                    await FirebaseMessaging.instance.requestPermission();

                    // 2. 抓取你这台测试手机的 Token
                    String? token = await FirebaseMessaging.instance.getToken();

                    if (token != null) {
                      debugPrint("✅ 抓到 Token 了: $token");

                      // 3. 强行塞进数据库，假装这是一个叫 "test_user_001" 的用户
                      await FirebaseFirestore.instance.collection('users').doc('test_user_001').set({
                        'fcm_token': token,
                        'name': 'Pei Jia (后端测试专属)', 
                      }, SetOptions(merge: true));

                      debugPrint("✅ 测试 Token 已强行写入 Firestore！去控制台看看吧！");
                      
                      // 如果在界面上弹出一个提示框就更好了
                      if(context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                           const SnackBar(content: Text('✅ Token 上传成功！请检查 Firestore 数据库。'))
                        );
                      }
                    }
                  } catch (e) {
                    debugPrint("❌ 发生错误: $e");
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange, // 给测试按钮换个醒目的颜色
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)
                ),
                child: const Text('【测试】强行获取并上传推送 Token'),
              ),
              // 👆 测试按钮代码结束 👆

            ],
          ),
        ),
      ),
    );
  }
}