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

// The lists change rarely, so they go first and are cached; everything that changes per request comes after.
// `who` names whose lists they are, for prompts that describe two people
function describeLists(lists, who = "The user", maxFilms = MAX_LIST_FILMS) {
    let remaining = maxFilms;
    const sections = [];
    for (const list of lists) {
        if (remaining <= 0) break;
        const films = list.films.slice(0, remaining);
        remaining -= films.length;
        const lines = films.map((film, i) => `${i + 1}. ${filmLabel(film)}${film.watched ? " ✓" : ""}`);
        sections.push(`List "${list.name}" (${list.films.length} films, best first):\n${lines.join("\n")}`);
    }
    if (!sections.length) return `${who} has no films in their lists yet.`;

    const all = lists.flatMap((list) => list.films);
    const watched = all.filter((film) => film.watched).length;
    const summary = [
        `${all.length} films in ${lists.length} list${lists.length === 1 ? "" : "s"}, ${watched} marked watched.`,
        `Eras: ${shares(all, (film) => (film.year ? `${film.year.slice(0, 3)}0s` : ""), 6)}.`,
        `Original languages: ${shares(all, (film) => film.language, 6)}.`,
    ].join(" ");
    return `${who}'s lists:\n\n${sections.join("\n\n")}\n\nAt a glance: ${summary}`;
}

function describeRequest(signals, count) {
    const parts = [];
    const titles = (films) => films.map(filmLabel).join("; ");
    if (signals.basedOnLists?.length) {
        const names = signals.basedOnLists.map((name) => `"${name}"`).join(" and ");
        parts.push(`The user wants recommendations based only on their ${signals.basedOnLists.length === 1 ? "list" : "lists"} ${names}: find films fans of ${signals.basedOnLists.length === 1 ? "that list" : "those lists"} would love, rather than drawing on the rest of their taste.`);
    }
    if (signals.languages?.length) {
        const names = signals.languages.map((code) => new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code);
        parts.push(`Only recommend films originally made in ${names.join(" or ")}. Every film must be in one of these languages.`);
    }
    if (signals.services?.length) {
        parts.push(`Only recommend films the user can stream right now on ${signals.services.join(" or ")}${signals.region ? ` in ${signals.region}` : ""}. Prefer well-known titles likely to be on these services.`);
    }
    if (signals.requiredGenres?.length) {
        parts.push(`The user chose to see only these genres right now: ${signals.requiredGenres.join(", ")}. Every film you recommend must belong to at least one of them. This overrides their usual leanings.`);
    }
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

// Feeds on the response text as it streams in and calls onPick with each recommendation the moment
// its closing brace arrives. The schema puts them one level inside {"recommendations": [...]} and
// gives them no nested objects, so a depth-2 object is a whole pick. Braces inside strings are skipped
function createPickParser(onPick) {
    let text = "";
    let scanned = 0;
    let depth = 0;
    let inString = false;
    let escaped = false;
    let pickStart = -1;
    return (chunk) => {
        text += chunk;
        for (; scanned < text.length; scanned++) {
            const char = text[scanned];
            if (inString) {
                if (escaped) escaped = false;
                else if (char === "\\") escaped = true;
                else if (char === '"') inString = false;
            } else if (char === '"') {
                inString = true;
            } else if (char === "{") {
                depth++;
                if (depth === 2) pickStart = scanned;
            } else if (char === "}") {
                if (depth === 2 && pickStart >= 0) {
                    try {
                        onPick(JSON.parse(text.slice(pickStart, scanned + 1)));
                    } catch (error) {
                        console.error("Skipping an AI pick that isn't valid JSON:", error.message);
                    }
                    pickStart = -1;
                }
                depth--;
            }
        }
    };
}

/// Asks Claude for films this user is likely to enjoy, streaming the answer. onPick, if given, gets each
/// { title, year, reason } as soon as Claude has written it; the full list is also returned at the end.
/// Fails before any pick arrives if AI isn't set up, the daily limit is reached, or the request fails
async function recommendFilms(user_id, lists, signals, count, onPick = () => {}) {
    const anthropic = getClient();
    takeDailyRequest(user_id);

    const picks = [];
    const parse = createPickParser((pick) => {
        picks.push(pick);
        onPick(pick);
    });
    const stream = anthropic.messages.stream({
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
                // An hour, since refills are often more than the default 5 minutes apart
                { type: "text", text: describeLists(lists), cache_control: { type: "ephemeral", ttl: "1h" } },
                { type: "text", text: describeRequest(signals, count) },
            ],
        }],
    });

    stream.on("text", parse);
    const response = await stream.finalMessage();

    const { usage: tokens } = response;
    console.log(`AI discover: ${tokens.input_tokens} input, ${tokens.cache_creation_input_tokens ?? 0} cache write, ${tokens.cache_read_input_tokens ?? 0} cache read, ${tokens.output_tokens} output tokens`);
    if (response.stop_reason === "refusal" || (response.stop_reason === "max_tokens" && !picks.length)) {
        throw new Error(`AI recommendations stopped early (${response.stop_reason})`);
    }
    // Cut off by max_tokens after some picks: keep the ones that were finished
    return picks;
}

const MOVIE_NIGHT_PROMPT = `You pick films for a group of friends to watch together on a movie night, using each person's film-ranking lists (films in rank order, best first, where ✓ marks films they've watched).

Find films everyone is likely to enjoy: look for overlaps in their tastes (directors, eras, countries, tone, themes, genres) and weigh highly ranked films most. Where tastes differ, pick films that bridge them rather than ones only one person would like.

Recommend real, released feature films. Never recommend a film that's in anyone's lists, so it's new to all of them. Always return the full number of films asked for, and mix safe crowd-pleasers with a few bolder picks. Follow any limits on genre, language or streaming service exactly.

For each film give its exact original release title as listed on TMDb, its release year, and one short sentence (under 25 words) on why it suits the group, naming films from two or more people's lists when you can.`;

// Everyone's lists together are cut to about this many films, so a movie night stays around half a cent
const MOVIE_NIGHT_TOTAL_FILMS = 4000;

/// Asks Claude for films a group would all enjoy and none of them has in their lists. people is
/// [{ name, lists }], the first being the user ("you"). constraints may limit genres, languages and streaming
/// services. Returns [{ title, year, reason }]. Counts against the user's daily limit
async function recommendForGroup(user_id, people, count, constraints = {}) {
    const anthropic = getClient();
    takeDailyRequest(user_id);

    const each = Math.floor(MOVIE_NIGHT_TOTAL_FILMS / people.length);
    const limits = [];
    if (constraints.genres?.length) limits.push(`Every film must be one of these genres: ${constraints.genres.join(", ")}.`);
    if (constraints.languages?.length) {
        const names = constraints.languages.map((code) => new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code);
        limits.push(`Every film must be originally in ${names.join(" or ")}.`);
    }
    if (constraints.services?.length) {
        limits.push(`Every film must be streaming now on ${constraints.services.join(" or ")}${constraints.region ? ` in ${constraints.region}` : ""}.`);
    }
    const names = people.slice(1).map((p) => p.name);
    const response = await anthropic.messages.create({
        model: MODEL,
        max_tokens: 4000,
        system: MOVIE_NIGHT_PROMPT,
        output_config: {
            effort: "low",
            format: { type: "json_schema", schema: OUTPUT_SCHEMA },
        },
        messages: [{
            role: "user",
            content: [
                ...people.map((person, i) => ({
                    type: "text",
                    text: describeLists(person.lists, i === 0 ? "The person asking (\"you\")" : person.name, each),
                })),
                { type: "text", text: `${limits.join(" ")}${limits.length ? "\n\n" : ""}Recommend ${count} films for all ${people.length} of them (you and ${names.join(", ")}) to watch together. In each reason, call the person asking "you" and everyone else by name.` },
            ],
        }],
    });

    const { usage: tokens } = response;
    console.log(`AI movie night (${people.length} people): ${tokens.input_tokens} input, ${tokens.output_tokens} output tokens`);
    if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens") {
        throw new Error(`Movie night recommendations stopped early (${response.stop_reason})`);
    }
    const text = response.content.find((block) => block.type === "text")?.text ?? "";
    return JSON.parse(text).recommendations ?? [];
}

const PLACEMENT_PROMPT = `You place a film in someone's ranked film list, best first, where they would most likely rank it themselves.

Read the whole list to understand their taste and how strict they are: which directors, genres, eras and tones they rank high or low, and how films similar to the new one are placed. Then choose the position for the new film, where 1 means it becomes their favourite and one more than the list's length means it goes at the bottom.

Give the position as an integer and one short sentence (under 15 words) naming the films it falls between or the pattern you used.`;

const PLACEMENT_SCHEMA = {
    type: "object",
    properties: {
        rank: { type: "integer" },
        reason: { type: "string" },
    },
    required: ["rank", "reason"],
    additionalProperties: false,
};

/// Asks Claude where a film belongs in one of the user's ranked lists. films is the list in rank order (without
/// the new film), as { title, year }. Returns { rank, reason } with rank clamped to 1...films.length + 1
async function placeInList(user_id, listName, films, newFilm) {
    const anthropic = getClient();
    takeDailyRequest(user_id);

    const lines = films.map((film, i) => `${i + 1}. ${filmLabel(film)}`).join("\n");
    const response = await anthropic.messages.create({
        model: MODEL,
        max_tokens: 500,
        system: PLACEMENT_PROMPT,
        output_config: {
            effort: "low",
            format: { type: "json_schema", schema: PLACEMENT_SCHEMA },
        },
        messages: [{
            role: "user",
            content: `The list "${listName}" (${films.length} films, best first):\n${lines}\n\nWhere would they rank ${filmLabel(newFilm)}?`,
        }],
    });
    const { usage: tokens } = response;
    console.log(`AI placement: ${tokens.input_tokens} input, ${tokens.output_tokens} output tokens`);
    if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens") {
        throw new Error(`Placement stopped early (${response.stop_reason})`);
    }
    const text = response.content.find((block) => block.type === "text")?.text ?? "";
    const { rank, reason } = JSON.parse(text);
    return { rank: Math.min(Math.max(Math.round(Number(rank) || films.length + 1), 1), films.length + 1), reason: String(reason ?? "").slice(0, 200) };
}

module.exports = { recommendFilms, recommendForGroup, placeInList, AIUnavailableError, AILimitError };
