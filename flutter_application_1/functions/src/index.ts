/**
 * Import function triggers from their respective submodules:
 *
 * import {onCall} from "firebase-functions/v2/https";
 * import {onDocumentWritten} from "firebase-functions/v2/firestore";
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */

import { setGlobalOptions } from "firebase-functions";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import {
    analyzeFridgeImage,
    generateNudges,
} from "./fridge-callables";

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
setGlobalOptions({ maxInstances: 10 });

export const sendExpiryReminders = onSchedule(
    {
        schedule: "every 60 minutes",
        timeZone: "Asia/Kuala_Lumpur",
        region: "asia-southeast1",
    },
    async () => {
        const db = admin.firestore();
        const nowMs = Date.now();
        const nextDay = admin.firestore.Timestamp.fromMillis(
            nowMs + 24 * 60 * 60 * 1000,
        );

        const inventorySnapshot = await db
            .collectionGroup("inventory")
            .where("estimated_expiry", "<=", nextDay)
            .limit(300)
            .get();

        let sent = 0;
        let skipped = 0;
        let failed = 0;

        for (const itemDoc of inventorySnapshot.docs) {
            const uid = itemDoc.ref.parent.parent?.id;
            if (!uid) {
                skipped += 1;
                continue;
            }

            const userDoc = await db.collection("users").doc(uid).get();
            const userData = userDoc.data() ?? {};
            const primaryToken =
                typeof userData["fcm_token"] === "string" ?
                    String(userData["fcm_token"]).trim() :
                    "";
            const tokenArray =
                Array.isArray(userData["fcm_tokens"]) ?
                    userData["fcm_tokens"].filter((value) =>
                        typeof value === "string" && value.trim().length > 0,
                    ) as string[] :
                    [];
            const token = primaryToken || tokenArray[0] || "";
            if (!token) {
                skipped += 1;
                continue;
            }

            const itemData = itemDoc.data();
            const status =
                typeof itemData["status"] === "string" ? itemData["status"] : "";
            const reminderSent = itemData["reminder_sent"] === true;
            if (status !== "active" || reminderSent) {
                skipped += 1;
                continue;
            }
            const itemName =
                typeof itemData["name"] === "string" &&
                    itemData["name"].trim().length > 0 ?
                    itemData["name"].trim() :
                    "an item";
            const expiry = itemData["estimated_expiry"] as
                admin.firestore.Timestamp | undefined;
            const daysLeft = expiry ?
                Math.max(
                    0,
                    Math.ceil((expiry.toMillis() - nowMs) / (24 * 60 * 60 * 1000)),
                ) :
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
            } catch {
                failed += 1;
            }
        }

        console.log("sendExpiryReminders result", {
            scanned: inventorySnapshot.size,
            sent,
            skipped,
            failed,
        });
    },
);

export { analyzeFridgeImage, generateNudges };

// export const helloWorld = onRequest((request, response) => {
//   logger.info("Hello logs!", {structuredData: true});
//   response.send("Hello from Firebase!");
// });
