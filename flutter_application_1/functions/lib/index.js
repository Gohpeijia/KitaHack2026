"use strict";
/**
 * Import function triggers from their respective submodules:
 *
 * import {onCall} from "firebase-functions/v2/https";
 * import {onDocumentWritten} from "firebase-functions/v2/firestore";
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.generateNudges = exports.analyzeFridgeImage = exports.sendExpiryReminders = void 0;
const firebase_functions_1 = require("firebase-functions");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const admin = __importStar(require("firebase-admin"));
const fridge_callables_1 = require("./fridge-callables");
Object.defineProperty(exports, "analyzeFridgeImage", { enumerable: true, get: function () { return fridge_callables_1.analyzeFridgeImage; } });
Object.defineProperty(exports, "generateNudges", { enumerable: true, get: function () { return fridge_callables_1.generateNudges; } });
if (!admin.apps.length) {
    admin.initializeApp();
}
// Start writing functions
// https://firebase.google.com/docs/functions/typescript
// For cost control, you can set the maximum number of containers that can be
// running at the same time. This helps mitigate the impact of unexpected
// traffic spikes by instead downgrading performance. This limit is a
// per-function limit. You can override the limit for each function using the
// `maxInstances` option in the function's options, e.g.
// `onRequest({ maxInstances: 5 }, (req, res) => { ... })`.
// NOTE: setGlobalOptions does not apply to functions using the v1 API. V1
// functions should each use functions.runWith({ maxInstances: 10 }) instead.
// In the v1 API, each function can only serve one request per container, so
// this will be the maximum concurrent request count.
(0, firebase_functions_1.setGlobalOptions)({ maxInstances: 10 });
exports.sendExpiryReminders = (0, scheduler_1.onSchedule)({
    schedule: "every 60 minutes",
    timeZone: "Asia/Kuala_Lumpur",
    region: "asia-southeast1",
}, async () => {
    var _a, _b;
    const db = admin.firestore();
    const nowMs = Date.now();
    const nextDay = admin.firestore.Timestamp.fromMillis(nowMs + 24 * 60 * 60 * 1000);
    const inventorySnapshot = await db
        .collectionGroup("inventory")
        .where("estimated_expiry", "<=", nextDay)
        .limit(300)
        .get();
    let sent = 0;
    let skipped = 0;
    let failed = 0;
    for (const itemDoc of inventorySnapshot.docs) {
        const uid = (_a = itemDoc.ref.parent.parent) === null || _a === void 0 ? void 0 : _a.id;
        if (!uid) {
            skipped += 1;
            continue;
        }
        const userDoc = await db.collection("users").doc(uid).get();
        const userData = (_b = userDoc.data()) !== null && _b !== void 0 ? _b : {};
        const primaryToken = typeof userData["fcm_token"] === "string" ?
            String(userData["fcm_token"]).trim() :
            "";
        const tokenArray = Array.isArray(userData["fcm_tokens"]) ?
            userData["fcm_tokens"].filter((value) => typeof value === "string" && value.trim().length > 0) :
            [];
        const token = primaryToken || tokenArray[0] || "";
        if (!token) {
            skipped += 1;
            continue;
        }
        const itemData = itemDoc.data();
        const status = typeof itemData["status"] === "string" ? itemData["status"] : "";
        const reminderSent = itemData["reminder_sent"] === true;
        if (status !== "active" || reminderSent) {
            skipped += 1;
            continue;
        }
        const itemName = typeof itemData["name"] === "string" &&
            itemData["name"].trim().length > 0 ?
            itemData["name"].trim() :
            "an item";
        const expiry = itemData["estimated_expiry"];
        const daysLeft = expiry ?
            Math.max(0, Math.ceil((expiry.toMillis() - nowMs) / (24 * 60 * 60 * 1000))) :
            0;
        try {
            await admin.messaging().send({
                token,
                notification: {
                    title: "Expiry reminder",
                    body: daysLeft <= 0 ?
                        `${itemName} may expire today. Use it soon.` :
                        `${itemName} may expire in ${daysLeft} day(s).`,
                },
                data: {
                    type: "expiry_reminder",
                    uid,
                    itemId: itemDoc.id,
                    itemName,
                },
            });
            await itemDoc.ref.set({
                reminder_sent: true,
                reminder_sent_at: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            sent += 1;
        }
        catch (_c) {
            failed += 1;
        }
    }
    console.log("sendExpiryReminders result", {
        scanned: inventorySnapshot.size,
        sent,
        skipped,
        failed,
    });
});
// export const helloWorld = onRequest((request, response) => {
//   logger.info("Hello logs!", {structuredData: true});
//   response.send("Hello from Firebase!");
// });
//# sourceMappingURL=index.js.map