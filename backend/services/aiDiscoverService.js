const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-haiku-5-5";
// Plenty for anyone's lists, while keeping each request to a fraction of a cent
const MAX_LIST_FILMS = 4000;
const DAILY_LIMIT = Number(process.env.AI_DAILY_LIMIT) || 40;

const SYSTEM_PROMPT = `You recommend films for the Discover tab of a film-ranking app. The user swipes through your picks one at a time and adds the ones they like to their lists.

You'll get the user's lists (films in rank order, best first, where ✓ marks films they've watched) with a summary of their eras and languages, and sometimes films they've liked, skipped or marked "not for me" in Discover, genres they lean towards or away from, how often they like what Discover shows them, their country and language, and an age range or pronouns they chose to share. Lists are the strongest signal: weigh highly ranked films most, and notice the patterns across the whole collection (directors, eras, countries, tone, themes), not just the top few. A list's name can say what it's for, such as a watchlist or a holiday list. When there are no lists, rely on the swipes and anything else provided, and if there's nothing at all, pick widely loved films across genres, eras and countries.

Recommend real, released feature films. Never recommend a film that's in the user's lists, that they liked, skipped or marked "not for me" in Discover, or that's in the already-suggested list: check each pick against them, and if it's there, choose a different film instead. Never include a film only to say it should be skipped. Always return the full number of films asked for. Liked films show what to find more of, and "not for me" films show what to steer away from. A skip only means "not now" or "seen it": don't read it as dislike, and don't avoid similar films because of it. If they like few of the films Discover shows them, stay closer to their lists; if they like many, be more adventurous. Prefer films likely to be available in their country, and in their language or with subtitles. Mix close matches with a few adventurous picks so the deck doesn't repeat itself. If the user is under 18, only recommend films suitable for their age. Use the age range and pronouns only as soft hints, never as a stereotype.

For each film give its exact original release title as listed on TMDb, its release year, and one short sentence (under 20 words) on why this user would like it, mentioning films or patterns from their lists when you can.`;

const OUTPUT_SCHEMA = {
    type: "object",
    properties: {
        recommendations: {
            type: "array",
            items: {
                type: "object",
                properties: {
                    title: { type: "string" },
                    year: { type: "integer" },
                    reason: { type: "string" },
                },
                required: ["title", "year", "reason"],
                additionalProperties: false,
            },
        },
    },
    required: ["recommendations"],
    additionalProperties: false,
};

class AIUnavailableError extends Error {}
class AILimitError extends Error {}

let client = null;
function getClient() {
    if (!process.env.ANTHROPIC_API_KEY) {
        throw new AIUnavailableError("ANTHROPIC_API_KEY is not set");
    }
    client ??= new Anthropic();
    return client;
}

// Requests per user per day. Kept in memory, so it resets when the server restarts
const usage = new Map();
function takeDailyRequest(user_id) {
    const today = new Date().toISOString().slice(0, 10);
    const entry = usage.get(user_id);
    const count = entry?.day === today ? entry.count : 0;
    if (count >= DAILY_LIMIT) {
        throw new AILimitError(`Daily limit of ${DAILY_LIMIT} AI requests reached`);
    }
    usage.set(user_id, { day: today, count: count + 1 });
}

const filmLabel = (film) => (film.year ? `${film.title} (${film.year})` : film.title);

// The share of films in each group, largest first, e.g. "2010s 34%, 2000s 22%"
function shares(films, groupOf, limit) {
    const counts = new Map();
    for (const film of films) {
        const group = groupOf(film);
        if (group) counts.set(group, (counts.get(group) ?? 0) + 1);
    }
    return [...counts.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, limit)
        .map(([group, n]) => `${group} ${Math.round((n / films.length) * 100)}%`)
        .join(", ");
}

// The lists change rarely, so they go first and are cached; everything that changes per request comes after
function describeLists(lists) {
    let remaining = MAX_LIST_FILMS;
    const sections = [];
    for (const list of lists) {
        if (remaining <= 0) break;
        const films = list.films.slice(0, remaining);
        remaining -= films.length;
        const lines = films.map((film, i) => `${i + 1}. ${filmLabel(film)}${film.watched ? " ✓" : ""}`);
        sections.push(`List "${list.name}" (${list.films.length} films, best first):\n${lines.join("\n")}`);
    }
    if (!sections.length) return "The user has no films in their lists yet.";

    const all = lists.flatMap((list) => list.films);
    const watched = all.filter((film) => film.watched).length;
    const summary = [
        `${all.length} films in ${lists.length} list${lists.length === 1 ? "" : "s"}, ${watched} marked watched.`,
        `Eras: ${shares(all, (film) => (film.year ? `${film.year.slice(0, 3)}0s` : ""), 6)}.`,
        `Original languages: ${shares(all, (film) => film.language, 6)}.`,
    ].join(" ");
    return `The user's lists:\n\n${sections.join("\n\n")}\n\nAt a glance: ${summary}`;
}

function describeRequest(signals, count) {
    const parts = [];
    const titles = (films) => films.map(filmLabel).join("; ");
    if (signals.liked.length) parts.push(`Liked in Discover, most recent first: ${titles(signals.liked)}`);
    if (signals.disliked.length) parts.push(`Marked "not for me" in Discover: ${titles(signals.disliked)}`);
    if (signals.passed.length) parts.push(`Skipped in Discover (not now, not a dislike): ${titles(signals.passed)}`);
    if (signals.favoriteGenres.length) parts.push(`Leans towards: ${signals.favoriteGenres.join(", ")}`);
    if (signals.avoidedGenres.length) parts.push(`Leans away from: ${signals.avoidedGenres.join(", ")}`);
    if (signals.swipeCount) parts.push(`Liked ${signals.likeCount} of the ${signals.swipeCount} films they've swiped in Discover`);
    if (signals.region) parts.push(`Country: ${signals.region}`);
    if (signals.language) parts.push(`Language: ${signals.language}`);
    if (signals.ageRange) parts.push(`Age range: ${signals.ageRange}`);
    if (signals.pronouns) parts.push(`Pronouns: ${signals.pronouns}`);
    if (signals.alreadySuggested.length) parts.push(`Already suggested, don't repeat: ${signals.alreadySuggested.join("; ")}`);
    parts.push(`Recommend ${count} films.`);
    return parts.join("\n\n");
}

/// Asks Claude for films this user is likely to enjoy. Returns [{ title, year, reason }]
async function recommendFilms(user_id, lists, signals, count) {
    const anthropic = getClient();
    takeDailyRequest(user_id);

    const response = await anthropic.messages.create({
        model: MODEL,
        max_tokens: 8000,
        system: SYSTEM_PROMPT,
        output_config: {
            effort: "low",
            format: { type: "json_schema", schema: OUTPUT_SCHEMA },
        },
        messages: [{
            role: "user",
            content: [
                { type: "text", text: describeLists(lists), cache_control: { type: "ephemeral" } },
                { type: "text", text: describeRequest(signals, count) },
            ],
        }],
    });

    if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens") {
        throw new Error(`AI recommendations stopped early (${response.stop_reason})`);
    }
    const text = response.content.find((block) => block.type === "text")?.text ?? "";
    const { usage: tokens } = response;
    console.log(`AI discover: ${tokens.input_tokens} input, ${tokens.cache_creation_input_tokens ?? 0} cache write, ${tokens.cache_read_input_tokens ?? 0} cache read, ${tokens.output_tokens} output tokens`);
    return JSON.parse(text).recommendations ?? [];
}

module.exports = { recommendFilms, AIUnavailableError, AILimitError };
