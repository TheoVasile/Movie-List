// Taste Match: how film-compatible two people are, 0-100, with the films behind it. Worked out from each person's
// ranked lists (watchlists and unranked collections say nothing about how much someone liked a film, so they're left
// out). Every film gets a place in each person's ranking from 0 (top of a list) to 1 (bottom), its best place across
// their ranked lists. Then:
// - Rank agreement on films both have ranked: a Spearman correlation on the order they put them in, together with how
//   close their places are (so both ranking a film near the top counts even when only a couple of films are shared)
// - Affinity: how alike the mix of genres and decades in their rankings is, with films nearer the top counting more
// The more films they share, the more the score is rank agreement; with few or none it's mostly affinity.
// Pure functions, so they can be tested without a database or TMDb

const MIN_RANKED = 5; // Ranked films each person needs before there's a match to show
const MIN_SHARED_WITHOUT_GENRES = 2; // Without genres to go on, films in common are all there is to compare
const SHARED_HALF_WEIGHT = 4; // Films in common at which rank agreement and affinity count the same
const LOVE_CUTOFF = 0.35; // "You both love": in the top 35% of both people's rankings
const FIGHT_GAP = 0.3; // "You fight over": at least 30% of a ranking apart

const GENRE_NAMES = {
    28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
    10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
    878: "Science Fiction", 53: "Thriller", 10752: "War", 37: "Western",
};

const TIERS = [
    { min: 90, label: "Cinematic soulmates" },
    { min: 75, label: "Same wavelength" },
    { min: 50, label: "Friendly rivals" },
    { min: 0, label: "Opposites attract" },
];

const tierFor = (score) => TIERS.find((tier) => score >= tier.min).label;
const clamp01 = (x) => Math.min(Math.max(x, 0), 1);

/// Rows of { tmdb_id, title, poster_path, release_date, list_id, position, list_size } (position 1 = top) as one
/// entry per film: its best place across the person's lists, as { ..., rank, place } where place is 0 (top) to 1
function placesFrom(rows) {
    const films = new Map();
    for (const row of rows) {
        const size = Number(row.list_size);
        if (size < 2) continue;
        const rank = Number(row.position);
        const place = (rank - 1) / (size - 1);
        const id = Number(row.tmdb_id);
        const current = films.get(id);
        // A better place wins; on a tie, the bigger list, whose ranking says more
        if (!current || place < current.place || (place === current.place && size > current.list_size)) {
            films.set(id, { tmdb_id: id, title: row.title, poster_path: row.poster_path ?? null,
                            release_date: row.release_date ?? "", rank, list_size: size, place });
        }
    }
    return films;
}

/// Ranks of values from 1, ties sharing the average of their ranks
function ranks(values) {
    const order = values.map((value, index) => ({ value, index })).sort((a, b) => a.value - b.value);
    const result = new Array(values.length);
    for (let i = 0; i < order.length;) {
        let j = i;
        while (j + 1 < order.length && order[j + 1].value === order[i].value) j++;
        for (let k = i; k <= j; k++) result[order[k].index] = (i + j) / 2 + 1;
        i = j + 1;
    }
    return result;
}

/// Spearman's rank correlation, -1...1: the Pearson correlation of the ranks, which handles ties. 0 when either side
/// has every value the same
function spearman(a, b) {
    const ra = ranks(a), rb = ranks(b);
    const mean = (xs) => xs.reduce((sum, x) => sum + x, 0) / xs.length;
    const ma = mean(ra), mb = mean(rb);
    let cov = 0, va = 0, vb = 0;
    for (let i = 0; i < ra.length; i++) {
        cov += (ra[i] - ma) * (rb[i] - mb);
        va += (ra[i] - ma) ** 2;
        vb += (rb[i] - mb) ** 2;
    }
    return va > 0 && vb > 0 ? cov / Math.sqrt(va * vb) : 0;
}

/// 1 when two weighted counts are in the same proportions, 0 when they share nothing
function cosine(a, b) {
    let dot = 0, la = 0, lb = 0;
    for (const [key, value] of a) {
        dot += value * (b.get(key) ?? 0);
        la += value * value;
    }
    for (const value of b.values()) lb += value * value;
    return la > 0 && lb > 0 ? dot / Math.sqrt(la * lb) : 0;
}

// How much a film says about someone's taste: the top of a ranking counts twice as much as the bottom
const weightOf = (film) => 1 - film.place / 2;

function genreWeights(films, genresOf) {
    const weights = new Map();
    for (const film of films.values()) {
        for (const genre of genresOf(film.tmdb_id) ?? []) {
            if (!GENRE_NAMES[genre]) continue;
            weights.set(genre, (weights.get(genre) ?? 0) + weightOf(film));
        }
    }
    return weights;
}

function decadeWeights(films) {
    const weights = new Map();
    for (const film of films.values()) {
        const year = Number(String(film.release_date).slice(0, 4));
        if (!year) continue;
        const decade = Math.floor(year / 10) * 10;
        weights.set(decade, (weights.get(decade) ?? 0) + weightOf(film));
    }
    return weights;
}

// Two people's taste mixes are almost never unlike each other (most rankings are full of dramas), so cosines below
// 0.4 count as nothing in common and the rest is stretched over 0...1
const stretch = (similarity) => clamp01((similarity - 0.4) / 0.6);

const share = (weights, key) => {
    let total = 0;
    for (const value of weights.values()) total += value;
    return total > 0 ? (weights.get(key) ?? 0) / total : 0;
};

const pair = (mine, theirs) => ({
    tmdb_id: mine.tmdb_id, title: mine.title, poster_path: mine.poster_path ?? theirs.poster_path, release_date: mine.release_date,
    my_rank: mine.rank, their_rank: theirs.rank,
});

/// The Taste Match between the viewer (mine) and someone else (theirs), each a Map from placesFrom. genresOf(tmdb_id)
/// gives a film's TMDb genre ids, or nothing when they aren't known. When there isn't enough to go on, enough is false
/// and needs says who has to rank more: "you", "them" or "overlap"
function computeTasteMatch(mine, theirs, genresOf = () => null) {
    if (mine.size < MIN_RANKED) return { enough: false, needs: "you" };
    if (theirs.size < MIN_RANKED) return { enough: false, needs: "them" };

    const shared = [...mine.keys()].filter((id) => theirs.has(id)).map((id) => [mine.get(id), theirs.get(id)]);
    const myGenres = genreWeights(mine, genresOf), theirGenres = genreWeights(theirs, genresOf);
    const hasGenres = myGenres.size > 0 && theirGenres.size > 0;
    if (!hasGenres && shared.length < MIN_SHARED_WITHOUT_GENRES) return { enough: false, needs: "overlap" };

    // Rank agreement on the films they share
    let agreement = null, correlation = null;
    if (shared.length) {
        const closeness = 1 - shared.reduce((sum, [a, b]) => sum + Math.abs(a.place - b.place), 0) / shared.length;
        if (shared.length >= 3) {
            correlation = spearman(shared.map(([a]) => a.place), shared.map(([, b]) => b.place));
            agreement = 0.6 * (correlation + 1) / 2 + 0.4 * closeness;
        } else {
            agreement = closeness;
        }
    }

    // Affinity: genres and decades
    const genreSimilarity = hasGenres ? cosine(myGenres, theirGenres) : null;
    const decadeSimilarity = cosine(decadeWeights(mine), decadeWeights(theirs));
    const affinity = hasGenres ? 0.65 * stretch(genreSimilarity) + 0.35 * stretch(decadeSimilarity) : stretch(decadeSimilarity);

    const rankWeight = shared.length / (shared.length + SHARED_HALF_WEIGHT);
    const raw = agreement === null ? affinity : rankWeight * agreement + (1 - rankWeight) * affinity;
    const score = Math.round(clamp01(raw) * 100);

    const bothLove = shared
        .filter(([a, b]) => a.place <= LOVE_CUTOFF && b.place <= LOVE_CUTOFF)
        .sort(([a1, b1], [a2, b2]) => Math.max(a1.place, b1.place) - Math.max(a2.place, b2.place) || a1.place + b1.place - (a2.place + b2.place))
        .slice(0, 3)
        .map(([a, b]) => pair(a, b));
    const fightOver = shared
        .filter(([a, b]) => Math.abs(a.place - b.place) >= FIGHT_GAP)
        .sort(([a1, b1], [a2, b2]) => Math.abs(a2.place - b2.place) - Math.abs(a1.place - b1.place))
        .slice(0, 2)
        .map(([a, b]) => pair(a, b));

    // The genre that's biggest for both of them: the one whose smaller share is largest
    let topGenre = null, topShare = 0;
    for (const genre of myGenres.keys()) {
        const both = Math.min(share(myGenres, genre), share(theirGenres, genre));
        if (both > topShare || (both === topShare && topGenre !== null && genre < topGenre)) {
            topGenre = genre;
            topShare = both;
        }
    }

    const round = (x) => (x === null ? null : Math.round(x * 100) / 100);
    return {
        enough: true,
        score,
        tier: tierFor(score),
        shared_count: shared.length,
        both_love: bothLove,
        fight_over: fightOver,
        top_genre: topGenre === null ? null : GENRE_NAMES[topGenre],
        // What the score is made of, so it can be explained
        breakdown: {
            rank_agreement: round(agreement),
            rank_correlation: round(correlation),
            genre_similarity: round(genreSimilarity),
            decade_similarity: round(decadeSimilarity),
            rank_weight: round(agreement === null ? 0 : rankWeight),
        },
    };
}

module.exports = { computeTasteMatch, placesFrom, spearman, tierFor, MIN_RANKED, GENRE_NAMES };
