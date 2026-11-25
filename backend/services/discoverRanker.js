// Scoring and ordering for Discover (and More Like This). Pure functions, so they can be tested and used by the
// offline evaluation (scripts/evalRecs.js) without a database or TMDb.
//
// A candidate's score mixes:
// - seed support: the sum, over the seed films whose TMDb recommendations include it, of the seed's weight times a
//   small decay for how far down that seed's recommendations it is. Films recommended from several of the user's
//   favourites rise to the top, like Movie Night's classic picks
// - taste: cosine(candidate, liked films) - DISLIKE_PENALTY x confidence x cosine(candidate, disliked films), where
//   confidence grows with how many films were disliked (services/tasteVector.js)
// - a little TMDb rating, so of two equal matches the better film comes first
// Then MMR re-ranks for variety, and explore and friend picks are slotted in at fixed places

const { cosine, filmVector, SIMILARITY_KINDS } = require("./tasteVector");

const SEED_LIMIT = 8;
const MAX_SEED_WEIGHT = 2;
// How fast seed support falls with the film's place in the seed's recommendations (0 = first)
const RANK_DECAY = 0.05;
const DISLIKE_PENALTY = 0.5;
const SCORE_WEIGHTS = { support: 0.55, taste: 0.35, quality: 0.1 };
// Taken off the score of a film in a genre the user leans away from
const AVOID_PENALTY = 0.15;
const MMR_LAMBDA = 0.7;
// Every EXPLORE_EVERY-th place goes to an explore pick (trending, or something outside the usual taste): ~14%
const EXPLORE_EVERY = 7;
// Where friends' recommendations go (0-based), i.e. 2nd, 6th and 12th
const FRIEND_POSITIONS = [1, 5, 11];
const MAX_FRIEND_PICKS = FRIEND_POSITIONS.length;

/// Seeds from a query parameter: comma-separated ids, each with an optional ":weight", e.g. "550:1,680:0.6,-1399".
/// Shows have negative ids. A missing or bad weight is 1 (older app builds send no weights); weights are capped
/// to 0...MAX_SEED_WEIGHT. Duplicates keep their first appearance
function parseSeeds(value, limit = SEED_LIMIT) {
    const seen = new Set();
    const seeds = [];
    for (const part of String(value ?? "").split(",")) {
        const [idText, weightText] = part.trim().split(":");
        const id = parseInt(idText, 10);
        if (!Number.isInteger(id) || id === 0 || seen.has(id)) continue;
        const parsed = Number(weightText);
        const weight = weightText === undefined || weightText === "" || !Number.isFinite(parsed)
            ? 1
            : Math.min(Math.max(parsed, 0), MAX_SEED_WEIGHT);
        seen.add(id);
        seeds.push({ id, weight });
        if (seeds.length >= limit) break;
    }
    return seeds;
}

/// Seed support for every film recommended from the seeds. seedResults: [{ seed: { id, weight }, results: [films in
/// TMDb's order, pages joined] }]. Returns Map id -> { support, seeds: [seed ids] }
function seedSupport(seedResults) {
    const support = new Map();
    for (const { seed, results } of seedResults) {
        const counted = new Set();
        results.forEach((film, rank) => {
            if (!film || counted.has(film.id)) return;
            counted.add(film.id);
            const entry = support.get(film.id) ?? { support: 0, seeds: [] };
            entry.support += seed.weight / (1 + RANK_DECAY * rank);
            entry.seeds.push(seed.id);
            support.set(film.id, entry);
        });
    }
    return support;
}

/// How well a film fits the user's taste: -DISLIKE_PENALTY...1, 0 without a taste vector
function tasteScore(vector, taste) {
    if (!taste || !vector?.size) return 0;
    return cosine(vector, taste.likes) - DISLIKE_PENALTY * (taste.dislikeConfidence ?? 1) * cosine(vector, taste.dislikes);
}

/// 0...1 from TMDb's rating: 5 or less is 0, 9 or more is 1
const quality = (voteAverage) => Math.min(Math.max(((voteAverage ?? 0) - 5) / 4, 0), 1);

/// The final score from seed support (relative to the best in the batch), taste and rating
function combineScore({ support = 0, maxSupport = 0, taste = 0, voteAverage = 0, avoided = false }) {
    const relativeSupport = maxSupport > 0 ? support / maxSupport : 0;
    return SCORE_WEIGHTS.support * relativeSupport
        + SCORE_WEIGHTS.taste * taste
        + SCORE_WEIGHTS.quality * quality(voteAverage)
        - (avoided ? AVOID_PENALTY : 0);
}

/// How alike two films are for variety: genres, keywords and directors
const similarityVector = (features) => filmVector(features, SIMILARITY_KINDS);

/// Greedy maximal marginal relevance: repeatedly takes the item with the best
/// lambda x relevance - (1 - lambda) x (similarity to the most similar item already taken), with relevance (score)
/// scaled to 0...1. items: [{ score, vector }] (vector from similarityVector). Returns the items in the new order
function mmr(items, lambda = MMR_LAMBDA, similarity = cosine) {
    if (items.length <= 1) return [...items];
    const scores = items.map((item) => item.score);
    const min = Math.min(...scores);
    const range = Math.max(...scores) - min || 1;
    const relevance = items.map((item) => (item.score - min) / range);
    const maxSimilarity = new Array(items.length).fill(0);
    const remaining = new Set(items.map((_, i) => i));
    const order = [];
    while (remaining.size) {
        let best = -1;
        let bestValue = -Infinity;
        for (const i of remaining) {
            const value = lambda * relevance[i] - (1 - lambda) * maxSimilarity[i];
            if (value > bestValue) {
                bestValue = value;
                best = i;
            }
        }
        remaining.delete(best);
        order.push(items[best]);
        for (const i of remaining) {
            const s = similarity(items[i].vector, items[best].vector);
            if (s > maxSimilarity[i]) maxSimilarity[i] = s;
        }
    }
    return order;
}

/// The ranked list with an explore pick in every EXPLORE_EVERY-th place, while there are explore picks. Leftover
/// explore picks are added at the end only when the list is short (fewer than minLength)
function blendExplore(ranked, explore, every = EXPLORE_EVERY, minLength = 40) {
    const result = [];
    let r = 0;
    let e = 0;
    while (r < ranked.length) {
        if ((result.length + 1) % every === 0 && e < explore.length) {
            result.push(explore[e++]);
        } else {
            result.push(ranked[r++]);
        }
    }
    while (e < explore.length && result.length < minLength) result.push(explore[e++]);
    return result;
}

/// Friends' picks put at FRIEND_POSITIONS (or at the end of a shorter list), without repeating any film
function placeFriends(ranked, friends, positions = FRIEND_POSITIONS) {
    const ids = new Set(friends.map((film) => film.id));
    const result = ranked.filter((film) => !ids.has(film.id));
    friends.slice(0, positions.length).forEach((film, i) => {
        result.splice(Math.min(positions[i], result.length), 0, film);
    });
    return result;
}

/// Re-orders films already in a sensible order (e.g. TMDb's recommendations for More Like This) by taste: each
/// keeps most of its place and gains or loses a little for fitting the taste. vectorOf(film) gives its vector
function rerankByTaste(films, taste, vectorOf) {
    if (!taste?.likes?.size) return films;
    return films
        .map((film, i) => ({ film, score: 0.6 / (1 + RANK_DECAY * i) + 0.4 * tasteScore(vectorOf(film), taste) }))
        .sort((a, b) => b.score - a.score)
        .map(({ film }) => film);
}

// Movie night: how much the group's Discover reactions can raise a pick, and lower it (for being like films people
// marked Not for Me). Less than one more person's favourites leading to a film (1), with GROUP_QUALITY for its rating,
// so what people ranked always counts for more
const GROUP_BOOST = 0.5;
const GROUP_PENALTY = 0.2;
const GROUP_QUALITY = 0.25;
// Reactions at which someone's taste from them counts for half as much as it would at most
const GROUP_HALF_CONFIDENCE = 5;

/// One person's Discover taste for a movie night, from their reactions alone ({ likes: [ids], dislikes: [ids] }).
/// features: Map id -> features, of whichever of those films are known
function groupTaste({ likes = [], dislikes = [] }, features = new Map()) {
    const combined = (ids) => {
        const vector = new Map();
        const known = ids.filter((id) => features.has(id));
        for (const id of known) {
            for (const [key, value] of filmVector(features.get(id))) vector.set(key, (vector.get(key) ?? 0) + value);
        }
        return { vector, confidence: known.length / (known.length + GROUP_HALF_CONFIDENCE) };
    };
    return { liked: new Set(likes), disliked: new Set(dislikes), like: combined(likes), dislike: combined(dislikes) };
}

/// How much the group's reactions move a film: -GROUP_PENALTY...GROUP_BOOST, the average over everyone of how well it
/// fits their reactions (a film they liked fits fully). 0 when nobody has reacted to anything
function groupBoost(id, vector, tastes) {
    if (!tastes.length) return 0;
    const fits = tastes.map(({ liked, like, dislike }) => (liked.has(id)
        ? 1
        : like.confidence * cosine(vector, like.vector) - DISLIKE_PENALTY * dislike.confidence * cosine(vector, dislike.vector)));
    const fit = fits.reduce((sum, value) => sum + value, 0) / fits.length;
    return Math.min(Math.max(GROUP_BOOST * fit, -GROUP_PENALTY), GROUP_BOOST);
}

/// Orders a group's candidates by base (what their lists say) plus groupBoost, and leaves out the films someone marked
/// Not for Me, unless fewer than count are left: then those follow, the fewest dislikes first. items:
/// [{ id, base, vector, ... }]; ties keep their order
function rankForGroup(items, tastes, count) {
    const scored = items.map((item) => ({
        item,
        score: item.base + groupBoost(item.id, item.vector, tastes),
        dislikes: tastes.filter(({ disliked }) => disliked.has(item.id)).length,
    })).sort((a, b) => a.dislikes - b.dislikes || b.score - a.score);
    const wanted = scored.filter(({ dislikes }) => !dislikes);
    return [...wanted, ...scored.slice(wanted.length, Math.max(count, wanted.length))].map(({ item }) => item);
}

module.exports = {
    groupTaste, groupBoost, rankForGroup, GROUP_BOOST, GROUP_PENALTY, GROUP_QUALITY,
    parseSeeds, seedSupport, tasteScore, combineScore, quality, similarityVector, mmr, blendExplore, placeFriends,
    rerankByTaste, SEED_LIMIT, MMR_LAMBDA, EXPLORE_EVERY, FRIEND_POSITIONS, MAX_FRIEND_PICKS, DISLIKE_PENALTY,
};
