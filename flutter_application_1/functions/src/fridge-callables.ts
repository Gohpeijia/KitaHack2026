import { genkit, z } from "genkit";
import { googleAI } from "@genkit-ai/google-genai";
import { onCallGenkit } from "firebase-functions/https";
import { defineSecret } from "firebase-functions/params";
import { Buffer } from "node:buffer";

const geminiApiKey = defineSecret("GEMINI_API_KEY");

const ai = genkit({
  plugins: [googleAI({ apiKey: geminiApiKey.value() })],
});

const fridgeItemSchema = z.object({
  name: z.string().min(1),
  quantity: z.number().int().min(1),
  estimated_expiry_days: z.number().int().min(0).max(30),
  freshness_score: z.number().int().min(1).max(5),
  sharing_eligible: z.boolean(),
});

const analyzeInputSchema = z.object({
  uid: z.string().min(1),
  imageUrl: z.string().url(),
});

const analyzeOutputSchema = z.object({
  items: z.array(fridgeItemSchema),
  error: z.string().optional(),
});

const nudgeActionSchema = z.object({
  title: z.string().min(1),
  why: z.string().min(1),
  duration: z.literal("~15 min"),
});

const generateNudgesInputSchema = z.object({
  uid: z.string().min(1),
  items: z.array(fridgeItemSchema),
});

const generateNudgesOutputSchema = z.object({
  actions: z.array(nudgeActionSchema).length(3),
  error: z.string().optional(),
});

type FridgeItem = z.infer<typeof fridgeItemSchema>;
type NudgeAction = z.infer<typeof nudgeActionSchema>;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function parseMarkdownJsonBlock(text: string): unknown {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const raw = fenced ? fenced[1] : text;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function normalizeItem(raw: Record<string, unknown>): FridgeItem {
  const name = String(raw["name"] ?? "Unknown Item").trim() || "Unknown Item";
  const quantity = clamp(Number(raw["quantity"] ?? 1) || 1, 1, 99);
  const expiryDays = clamp(
    Number(raw["estimated_expiry_days"] ?? 3) || 3,
    0,
    30,
  );
  const freshness = clamp(Number(raw["freshness_score"] ?? 3) || 3, 1, 5);
  const sharingEligible = raw["sharing_eligible"] === true;
  return {
    name,
    quantity: Math.round(quantity),
    estimated_expiry_days: Math.round(expiryDays),
    freshness_score: Math.round(freshness),
    sharing_eligible: sharingEligible,
  };
}

function fallbackAnalyzedItems(): FridgeItem[] {
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

function fallbackNudges(items: FridgeItem[]): NudgeAction[] {
  const sorted = [...items].sort((a, b) => {
    const expiryCmp = a.estimated_expiry_days - b.estimated_expiry_days;
    if (expiryCmp !== 0) return expiryCmp;
    return a.freshness_score - b.freshness_score;
  });
  const first = sorted[0]?.name ?? "fridge item";
  const second = sorted[1]?.name ?? first;
  const third = sorted[2]?.name ?? second;
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

async function fetchImageDataUrl(imageUrl: string): Promise<string> {
  const response = await fetch(imageUrl);
  if (!response.ok) {
    throw new Error(`Image fetch failed: HTTP ${response.status}`);
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  const contentType = response.headers.get("content-type") ?? "image/jpeg";
  return `data:${contentType};base64,${buffer.toString("base64")}`;
}

const analyzeFridgeImageFlow = ai.defineFlow(
  {
    name: "analyzeFridgeImageFlow",
    inputSchema: analyzeInputSchema,
    outputSchema: analyzeOutputSchema,
  },
  async (input) => {
    try {
      const dataUrl = await fetchImageDataUrl(input.imageUrl);
      const prompt = [
        "Analyze this fridge image and output strict JSON.",
        "Return only fields:",
        "name, quantity, estimated_expiry_days, freshness_score, sharing_eligible.",
        "Do not include markdown.",
      ].join(" ");

      const response = await ai.generate({
        model: googleAI.model("gemini-2.5-flash"),
        prompt: [
          { text: prompt },
          { media: { url: dataUrl } },
        ] as any,
        output: { schema: analyzeOutputSchema },
      });

      if (response.output?.items?.length) {
        const normalized = response.output.items.map((item) => normalizeItem(item));
        return { items: normalized };
      }

      const parsed = parseMarkdownJsonBlock(response.text ?? "");
      if (parsed && typeof parsed === "object" && "items" in parsed) {
        const rawItems = (parsed as { items?: unknown }).items;
        if (Array.isArray(rawItems)) {
          const normalized = rawItems
            .filter((item): item is Record<string, unknown> =>
              typeof item === "object" && item !== null
            )
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
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      return {
        items: fallbackAnalyzedItems(),
        error: `analyzeFridgeImage failed: ${message}`,
      };
    }
  },
);

const generateNudgesFlow = ai.defineFlow(
  {
    name: "generateNudgesFlow",
    inputSchema: generateNudgesInputSchema,
    outputSchema: generateNudgesOutputSchema,
  },
  async (input) => {
    const prioritized = [...input.items].sort((a, b) => {
      const expiryCmp = a.estimated_expiry_days - b.estimated_expiry_days;
      if (expiryCmp !== 0) return expiryCmp;
      return a.freshness_score - b.freshness_score;
    }).slice(0, 6);

    try {
      const response = await ai.generate({
        model: googleAI.model("gemini-2.5-flash"),
        prompt: [
          {
            text: [
              "Create exactly 3 short food-saving actions from this inventory.",
              'Each action must include "title", "why", and duration "~15 min".',
              `Inventory: ${JSON.stringify(prioritized)}`,
            ].join(" "),
          },
        ] as any,
        output: { schema: generateNudgesOutputSchema },
      });

      if (response.output?.actions?.length == 3) {
        const actions = response.output.actions.map((action) => ({
          title: action.title.trim(),
          why: action.why.trim(),
          duration: "~15 min" as const,
        }));
        return { actions };
      }

      return {
        actions: fallbackNudges(prioritized),
        error: "Model returned invalid nudge output. Fallback nudges used.",
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      return {
        actions: fallbackNudges(prioritized),
        error: `generateNudges failed: ${message}`,
      };
    }
  },
);

export const analyzeFridgeImage = onCallGenkit(
  {
    secrets: [geminiApiKey],
  },
  analyzeFridgeImageFlow,
);

export const generateNudges = onCallGenkit(
  {
    secrets: [geminiApiKey],
  },
  generateNudgesFlow,
);
