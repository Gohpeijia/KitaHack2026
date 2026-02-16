/// if need to use thiks script, use "import 'impact_aggregator.dart';" "
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class ImpactAggregator {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// label the food as "saved" and calculate the carbon emission saved by this action, then update the user's total carbon saved in a safe way.
  /// [inventoryId]: ID of the food inventory item 
  /// [userId]:　UID
  /// [weightKg]: mass of the food in kilograms
  Future<void> markFoodAsSaved(String inventoryId, String userId, double weightKg) async {
    try { 
      debugPrint("📊 Calculating carbon impact for food item $inventoryId");

      // 1. calculate the CO2 saved by this action. For simplicity, we use a fixed emission factor (kg CO2 per kg of food waste). In a real app, this could be more complex and depend on the type of food.
      const double emissionFactor = 2.5; 
      final double co2Saved = weightKg * emissionFactor;

      // 2. create WriteBatch
      // Batch benifits - Atomicity: All operations in the batch either succeed or fail together, which helps maintain data integrity.
      WriteBatch batch = _firestore.batch();

      // action A: update the inventory item status to "consumed"
      DocumentReference itemRef = _firestore.collection('inventories').doc(inventoryId);
      batch.update(itemRef, {'status': 'consumed'});

      // action B: update the user's total CO2 saved. We use FieldValue.increment to safely increment the value without worrying about concurrent updates.
      DocumentReference userRef = _firestore.collection('users').doc(userId);
      // FieldValue.increment is Firebase 
      batch.set(userRef, {
        'total_co2_saved': FieldValue.increment(co2Saved)
      }, SetOptions(merge: true)); // merge: true is no have to worry about overwriting other user data, only update the total_co2_saved field

      // 3. submit the batch
      await batch.commit();

      debugPrint("🌍 Reduced $co2Saved kg of carbon emissions!");

    } catch (e) {
      debugPrint("❌ Failed to calculate impact: $e");
    }
  }
}