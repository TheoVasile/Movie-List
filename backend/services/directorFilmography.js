// Which of a person's TMDb movie credits count as films they directed, for Directors & Franchises.
//
// Every credit with job "Director" (not the whole Directing department, which includes assistant directors) that
// has come out, has a poster and isn't adult is a candidate. Shorts and segments of anthologies are then left out
// by length rather than popularity: a feature is at least 40 minutes (the Academy's definition). Popularity alone
// can't tell them apart, since a director's early features can have fewer votes than a promotional short of theirs
// (Taika Waititi's Boy has 515, his Team Thor short 601), and a bar relative to their most-rated film dropped the
// early features of anyone who later made a blockbuster

// Shortest feature film, in minutes
const FEATURE_MINUTES = 40;
// Fewer votes than this is noise, such as a one-minute segment of a 42-director anthology
const MIN_VOTES = 10;
// When TMDb doesn't know a film's length, only a film enough people have rated counts
const MIN_VOTES_UNKNOWN_LENGTH = 50;

const today = () => new Date().toISOString().slice(0, 10);

const released = (movie, on) => /^\d{4}-\d{2}-\d{2}$/.test(movie.release_date ?? "") && movie.release_date <= on;

/// The person's director credits that could be shown: released, with a poster, enough votes, each film once
function directingCandidates(credits, on = today()) {
    const seen = new Set();
    return (credits?.crew ?? [])
        .filter((movie) => movie.job === "Director" && released(movie, on) && movie.poster_path && !movie.adult)
        .filter((movie) => (movie.vote_count ?? 0) >= MIN_VOTES)
        .filter((movie) => !seen.has(movie.id) && seen.add(movie.id));
}

/// Whether a film of this length (minutes; 0 or null when TMDb doesn't know) is a feature
function isFeature(movie, runtime) {
    if (runtime > 0) return runtime >= FEATURE_MINUTES;
    return (movie.vote_count ?? 0) >= MIN_VOTES_UNKNOWN_LENGTH;
}

/// The feature films a person directed, oldest first, from their movie_credits. runtimeOf(id) resolves to a
/// film's length in minutes, or null when it can't be found out
async function directedFilms(credits, runtimeOf, { on = today(), map = (items, fn) => Promise.all(items.map(fn)) } = {}) {
    const candidates = directingCandidates(credits, on);
    const runtimes = await map(candidates, (movie) => Promise.resolve(runtimeOf(movie.id)).catch(() => null));
    return candidates
        .filter((movie, index) => isFeature(movie, runtimes[index]))
        .sort((a, b) => a.release_date.localeCompare(b.release_date) || a.id - b.id);
}

module.exports = { directedFilms, directingCandidates, isFeature, FEATURE_MINUTES, MIN_VOTES, MIN_VOTES_UNKNOWN_LENGTH };
