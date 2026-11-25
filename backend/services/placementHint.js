// Where Compare should start when a film is added to a ranked list, from the user's Discover reactions: a film they
// liked (or like ones they liked) starts higher up, one they marked Not for Me lower down. Only the first comparison
// moves: the answers decide the place, as always. Pure functions, so they can be tested without a database or TMDb.
//
// The start is a place in the list as a share of its length (0 = top), 0.5 without any signal, less
// OWN_SHIFT for the user's own reaction to the film and up to SIMILAR_SHIFT for the reacted films most like it

const { cosine, filmVector } = require("./tasteVector");

// Films a list needs, besides the new one, for where to start to matter
const MIN_FILMS = 4;
const OWN_SHIFT = 0.18;
const SIMILAR_SHIFT = 0.12;
const MAX_SHIFT = 0.25;
// The most alike reacted films counted, and how alike they have to be (cosine)
const MAX_SIMILAR = 10;
const MIN_SIMILARITY = 0.35;
// Similarity that counts for half as much as it would at most, so one look-alike says little
const HALF_WEIGHT = 1.5;

/// The reacted films most like a film, most alike first. reactions: [{ tmdb_id, reaction }]; features: Map id ->
/// features, the film's own included. Returns [{ tmdb_id, reaction, similarity }]
function similarReactions(tmdb_id, reactions, features) {
    const film = features.get(tmdb_id);
    if (!film) return [];
    const vector = filmVector(film);
    return reactions
        .filter((row) => row.tmdb_id !== tmdb_id && features.has(row.tmdb_id))
        .map((row) => ({ ...row, similarity: cosine(vector, filmVector(features.get(row.tmdb_id))) }))
        .filter((row) => row.similarity >= MIN_SIMILARITY)
        .sort((a, b) => b.similarity - a.similarity);
}

/// Where to start, for a list of `count` films besides this one: { start_index (0 = top, null for the middle as
/// usual), count, basis: "like" | "dislike" | "similar" | "none" }
function placementHint({ tmdb_id, count, ranked = true, reactions = [], features = new Map() }) {
    const none = { start_index: null, count, basis: "none" };
    if (!ranked || count < MIN_FILMS) return none;
    const own = reactions.find((row) => row.tmdb_id === tmdb_id)?.reaction;
    const r = own === "like" ? 1 : own === "dislike" ? -1 : 0;
    const similar = similarReactions(tmdb_id, reactions, features).slice(0, MAX_SIMILAR);
    const total = similar.reduce((sum, row) => sum + row.similarity, 0);
    const signed = similar.reduce((sum, row) => sum + (row.reaction === "like" ? row.similarity : -row.similarity), 0);
    const q = signed / (total + HALF_WEIGHT);
    if (!r && !q) return none;
    const shift = Math.min(Math.max(OWN_SHIFT * r + SIMILAR_SHIFT * q, -MAX_SHIFT), MAX_SHIFT);
    return { start_index: Math.round((0.5 - shift) * (count - 1)), count, basis: r ? own : "similar" };
}

module.exports = { placementHint, similarReactions, MIN_FILMS };
