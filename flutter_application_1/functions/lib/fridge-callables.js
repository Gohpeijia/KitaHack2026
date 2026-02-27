"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.generateNudges = exports.analyzeFridgeImage = void 0;
const genkit_1 = require("genkit");
const google_genai_1 = require("@genkit-ai/google-genai");
const https_1 = require("firebase-functions/https");
const params_1 = require("firebase-functions/params");
const node_buffer_1 = require("node:buffer");
const geminiApiKey = (0, params_1.defineSecret)("GEMINI_API_KEY");
const ai = (0, genkit_1.genkit)({
    plugins: [(0, google_genai_1.googleAI)({ apiKey: geminiApiKey.value() })],
});
const fridgeItemSchema = genkit_1.z.object({
    name: genkit_1.z.string().min(1),
    quantity: genkit_1.z.number().int().min(1),
    estimated_expiry_days: genkit_1.z.number().int().min(0).max(30),
    freshness_score: genkit_1.z.number().int().min(1).max(5),
    sharing_eligible: genkit_1.z.boolean(),
});
const analyzeInputSchema = genkit_1.z.object({
    uid: genkit_1.z.string().min(1),
    imageUrl: genkit_1.z.string().url(),
});
const analyzeOutputSchema = genkit_1.z.object({
    items: genkit_1.z.array(fridgeItemSchema),
    error: genkit_1.z.string().optional(),
});
const nudgeActionSchema = genkit_1.z.object({
    title: genkit_1.z.string().min(1),
    why: genkit_1.z.string().min(1),
    duration: genkit_1.z.literal("~15 min"),
});
const generateNudgesInputSchema = genkit_1.z.object({
    uid: genkit_1.z.string().min(1),
    items: genkit_1.z.array(fridgeItemSchema),
});
const generateNudgesOutputSchema = genkit_1.z.object({
    actions: genkit_1.z.array(nudgeActionSchema).length(3),
    error: genkit_1.z.string().optional(),
});
function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
}
function parseMarkdownJsonBlock(text) {
    const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
    const raw = fenced ? fenced[1] : text;
    try {
        return JSON.parse(raw);
    }
    catch (_a) {
        return null;
    }
}
function normalizeItem(raw) {
    var _a, _b, _c, _d;
    const name = String((_a = raw["name"]) !== null && _a !== void 0 ? _a : "Unknown Item").trim() || "Unknown Item";
    const quantity = clamp(Number((_b = raw["quantity"]) !== null && _b !== void 0 ? _b : 1) || 1, 1, 99);
    const expiryDays = clamp(Number((_c = raw["estimated_expiry_days"]) !== null && _c !== void 0 ? _c : 3) || 3, 0, 30);
    const freshness = clamp(Number((_d = raw["freshness_score"]) !== null && _d !== void 0 ? _d : 3) || 3, 1, 5);
    const sharingEligible = raw["sharing_eligible"] === true;
    return {
        name,
        quantity: Math.round(quantity),
        estimated_expiry_days: Math.round(expiryDays),
        freshness_score: Math.round(freshness),
        sharing_eligible: sharingEligible,
    };
}
function fallbackAnalyzedItems() {
    return [
        {
            name: "Milk",
            quantity: 1,
            estimated_expiry_days: 1,
            freshness_score: 2,
            sharing_eligible: false,
        },
        {
            name: "Spinach",
            quantity: 1,
            estimated_expiry_days: 0,
            freshness_score: 1,
            sharing_eligible: true,
        },
        {
            name: "Eggs",
            quantity: 6,
            estimated_expiry_days: 6,
            freshness_score: 4,
            sharing_eligible: false,
        },
    ];
}
function fallbackNudges(items) {
    var _a, _b, _c, _d, _e, _f;
    const sorted = [...items].sort((a, b) => {
        const expiryCmp = a.estimated_expiry_days - b.estimated_expiry_days;
        if (expiryCmp !== 0)
            return expiryCmp;
        return a.freshness_score - b.freshness_score;
    });
    const first = (_b = (_a = sorted[0]) === null || _a === void 0 ? void 0 : _a.name) !== null && _b !== void 0 ? _b : "fridge item";
    const second = (_d = (_c = sorted[1]) === null || _c === void 0 ? void 0 : _c.name) !== null && _d !== void 0 ? _d : first;
    const third = (_f = (_e = sorted[2]) === null || _e === void 0 ? void 0 : _e.name) !== null && _f !== void 0 ? _f : second;
    return [
        {
            title: `Cook ${first} today`,
            why: "Shortest expiry first to reduce waste.",
            duration: "~15 min",
        },
        {
            title: `Use ${second} in a quick dish`,
            why: "Keeps medium-risk food from expiring.",
            duration: "~15 min",
        },
        {
            title: `Prep ${third} for tomorrow`,
            why: "Prepping now extends usability and avoids spoilage.",
            duration: "~15 min",
        },
    ];
}
async function fetchImageDataUrl(imageUrl) {
    var _a;
    const response = await fetch(imageUrl);
    if (!response.ok) {
        throw new Error(`Image fetch failed: HTTP ${response.status}`);
    }
    const buffer = node_buffer_1.Buffer.from(await response.arrayBuffer());
    const contentType = (_a = response.headers.get("content-type")) !== null && _a !== void 0 ? _a : "image/jpeg";
    return `data:${contentType};base64,${buffer.toString("base64")}`;
}
const analyzeFridgeImageFlow = ai.defineFlow({
    name: "analyzeFridgeImageFlow",
    inputSchema: analyzeInputSchema,
    outputSchema: analyzeOutputSchema,
}, async (input) => {
    var _a, _b, _c;
    try {
        const dataUrl = await fetchImageDataUrl(input.imageUrl);
        const prompt = [
            "Analyze this fridge image and output strict JSON.",
            "Return only fields:",
            "name, quantity, estimated_expiry_days, freshness_score, sharing_eligible.",
            "Do not include markdown.",
        ].join(" ");
        const response = await ai.generate({
            model: google_genai_1.googleAI.model("gemini-2.5-flash"),
            prompt: [
                { text: prompt },
                { media: { url: dataUrl } },
            ],
            output: { schema: analyzeOutputSchema },
        });
        if ((_b = (_a = response.output) === null || _a === void 0 ? void 0 : _a.items) === null || _b === void 0 ? void 0 : _b.length) {
            const normalized = response.output.items.map((item) => normalizeItem(item));
            return { items: normalized };
        }
        const parsed = parseMarkdownJsonBlock((_c = response.text) !== null && _c !== void 0 ? _c : "");
        if (parsed && typeof parsed === "object" && "items" in parsed) {
            const rawItems = parsed.items;
            if (Array.isArray(rawItems)) {
                const normalized = rawItems
                    .filter((item) => typeof item === "object" && item !== null)
                    .map((item) => normalizeItem(item));
                if (normalized.length > 0) {
                    return { items: normalized };
                }
            }
        }
        return {
            items: fallbackAnalyzedItems(),
            error: "Model returned empty output. Fallback items used.",
        };
    }
    catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        return {
            items: fallbackAnalyzedItems(),
            error: `analyzeFridgeImage failed: ${message}`,
        };
    }
});
const generateNudgesFlow = ai.defineFlow({
    name: "generateNudgesFlow",
    inputSchema: generateNudgesInputSchema,
    outputSchema: generateNudgesOutputSchema,
}, async (input) => {
    var _a, _b;
    const prioritized = [...input.items].sort((a, b) => {
        const expiryCmp = a.estimated_expiry_days - b.estimated_expiry_days;
        if (expiryCmp !== 0)
            return expiryCmp;
        return a.freshness_score - b.freshness_score;
    }).slice(0, 6);
    try {
        const response = await ai.generate({
            model: google_genai_1.googleAI.model("gemini-2.5-flash"),
            prompt: [
                {
                    text: [
                        "Create exactly 3 short food-saving actions from this inventory.",
                        'Each action must include "title", "why", and duration "~15 min".',
                        `Inventory: ${JSON.stringify(prioritized)}`,
                    ].join(" "),
                },
            ],
            output: { schema: generateNudgesOutputSchema },
        });
        if (((_b = (_a = response.output) === null || _a === void 0 ? void 0 : _a.actions) === null || _b === void 0 ? void 0 : _b.length) == 3) {
            const actions = response.output.actions.map((action) => ({
                title: action.title.trim(),
                why: action.why.trim(),
                duration: "~15 min",
            }));
            return { actions };
        }
        return {
            actions: fallbackNudges(prioritized),
            error: "Model returned invalid nudge output. Fallback nudges used.",
        };
    }
    catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        return {
            actions: fallbackNudges(prioritized),
            error: `generateNudges failed: ${message}`,
        };
    }
});
exports.analyzeFridgeImage = (0, https_1.onCallGenkit)({
    secrets: [geminiApiKey],
}, analyzeFridgeImageFlow);
exports.generateNudges = (0, https_1.onCallGenkit)({
    secrets: [geminiApiKey],
}, generateNudgesFlow);
//# sourceMappingURL=fridge-callables.js.map