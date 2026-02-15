import 'dart:io';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GeminiService {
  // Core functions: Image -> AI -> Database
  static Future<void> analyzeAndSaveFridgeImage(File imageFile, String userId) async {
    try {
      // 1. Configure the Gemini API
      // Note: Please enter your actual API Key within the quotation marks below.
      final apiKey = dotenv.env['GEMINI_API_KEY']; 
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception("API Key 未找到！请检查 .env 文件。");
      }
      final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: apiKey);

      // 2. convert the image file to bytes and create a DataPart for the API
      final imageBytes = await imageFile.readAsBytes();
      final imagePart = DataPart('image/jpeg', imageBytes);
      
      // 3. set up the prompt for the AI to analyze the image and return structured data
      final prompt = TextPart('''
        Analyze this image of food/ingredients in a fridge. 
        Identify the items and return ONLY a valid JSON array. 
        For each item, include exactly these keys:
        - "name": string
        - "quantity": string or number
        - "expiry_date": string (YYYY-MM-DD or "Unknown")
        
        Example: [{"name": "Apple", "quantity": 3, "expiry_date": "2026-03-01"}]
      ''');

      debugPrint("sending to Gemini for analysing...");
      
      // 4. use the Gemini API to analyze
      final response = await model.generateContent([
        Content.multi([prompt, imagePart])
      ]);
      
      String rawText = response.text ?? "[]";
      debugPrint("Gemini return result: $rawText");

      // 5. clear and parse the response to extract the JSON array
      if (rawText.contains('```json')) {
        rawText = rawText.split('```json')[1].split('```')[0].trim();
      } else if (rawText.contains('```')) {
        rawText = rawText.split('```')[1].trim();
      }
      
      List<dynamic> items = jsonDecode(rawText);

      // 6. write the extracted items into Firestore under the user's inventory
      final db = FirebaseFirestore.instance;
      // The path here corresponds to your designed database: users -> specific user ID -> inventory
      final collectionRef = db.collection('users').doc(userId).collection('inventory');

      final batch = db.batch();
      for (var item in items) {
        final docRef = collectionRef.doc(); 
        batch.set(docRef, {
          'name': item['name'],
          'quantity': item['quantity'],
          'expiryDate': item['expiry_date'],
          'addedAt': FieldValue.serverTimestamp(), 
        });
      }
      
      await batch.commit();
      debugPrint("🎉 Success！${items.length} ingredients have been stored in the database.！");

    } catch (e) {
      debugPrint("❌ Occur error: $e");
    }
  }
}