const pool = require("../config/db");
const { fetchDiary } = require("./watchedModel");
const { visibleTo } = require("./listModel");

// Year in Review: what the user watched in a year, from their diary, plus the friend whose taste is closest to
// theirs. Watches saved in bulk (imports, marking a whole list) are left out, since their dates are when they were
// recorded rather than when the films were seen. Genres and TMDb scores are worked out on the phone, which
// already keeps them for every film

// The friend whose lists overlap most with the user's, counting only lists the user can see. Overlap is the
// films they share divided by the square root of each one's film count, so a friend with a huge list doesn't win
// just by having everything. null when nobody shares at least 3 films
async function closestFriend(user_id) {
    const result = await pool.query(
        `WITH mine AS (
             SELECT DISTINCT lm.movie_id FROM lists l JOIN list_movies lm ON lm.list_id = l.id WHERE l.user_id = $1
         ), theirs AS (
             SELECT DISTINCT l.user_id, lm.movie_id
             FROM follows f JOIN lists l ON l.user_id = f.followee_id JOIN list_movies lm ON lm.list_id = l.id
             WHERE f.follower_id = $1 AND f.accepted AND ${visibleTo("$1")}
         ), scored AS (
             SELECT t.user_id, COUNT(*) FILTER (WHERE t.movie_id IN (SELECT movie_id FROM mine))::int AS shared, COUNT(*)::int AS total
             FROM theirs t GROUP BY t.user_id
         )
         SELECT s.user_id, s.shared, u.handle, u.username AS display_name,
                FLOOR(EXTRACT(EPOCH FROM u.avatar_updated_at) * 1000)::double precision AS avatar_version
         FROM scored s JOIN users u ON u.firebase_uid = s.user_id
         WHERE s.shared >= 3
         ORDER BY s.shared / sqrt(s.total::float * GREATEST((SELECT COUNT(*) FROM mine), 1)) DESC, s.shared DESC
         LIMIT 1`,
        [user_id]
    );
    const friend = result.rows[0];
    if (!friend) return null;
    // A film they both rank highly, to name in the review
    const example = await pool.query(
        `SELECT m.title FROM movies m
         JOIN (SELECT lm.movie_id, MIN(lm.rank) AS rank FROM lists l JOIN list_movies lm ON lm.list_id = l.id WHERE l.user_id = $1 GROUP BY 1) a ON a.movie_id = m.id
         JOIN (SELECT lm.movie_id, MIN(lm.rank) AS rank FROM lists l JOIN list_movies lm ON lm.list_id = l.id
               WHERE l.user_id = $2 AND ${visibleTo("$1")} GROUP BY 1) b ON b.movie_id = m.id
         ORDER BY a.rank + b.rank LIMIT 1`,
        [user_id, friend.user_id]
    );
    return {
        handle: friend.handle,
        display_name: friend.display_name,
        avatar_version: friend.avatar_version,
        shared: friend.shared,
        example_title: example.rows[0]?.title ?? null,
    };
}

const film = (entry) => ({ tmdb_id: entry.tmdb_id, title: entry.title, poster_path: entry.poster_path, release_date: entry.release_date });

/// The user's year. year defaults to the current one
async function yearReview(user_id, year) {
    const diary = (await fetchDiary(user_id)).filter((entry) => !entry.bulk);
    const yearOf = (entry) => new Date(entry.watched_at).getUTCFullYear();
    const years = [...new Set(diary.map(yearOf))].sort((a, b) => b - a);
    const watches = diary.filter((entry) => yearOf(entry) === year).reverse(); // oldest first

    const months = Array(12).fill(0);
    for (const entry of watches) months[new Date(entry.watched_at).getUTCMonth()]++;
    const busiest = Math.max(...months);

    // Each film once, in the order first watched that year
    const films = [];
    const timesWatched = new Map();
    for (const entry of watches) {
        if (!timesWatched.has(entry.tmdb_id)) films.push(film(entry));
        timesWatched.set(entry.tmdb_id, (timesWatched.get(entry.tmdb_id) ?? 0) + 1);
    }
    const [rewatchedId, rewatchedCount] = [...timesWatched].sort((a, b) => b[1] - a[1])[0] ?? [];

    // The year's film ranked highest in any of the user's lists, relative to the list's length, among lists with
    // at least 5 films so a 2-film list's #1 doesn't win
    let newFavourite = null;
    if (films.length) {
        const best = await pool.query(
            `SELECT m.tmdb_id::int AS tmdb_id, lm.rank, l.name AS list_name, sizes.n
             FROM lists l
             JOIN (SELECT list_id, COUNT(*)::int AS n FROM list_movies GROUP BY list_id) sizes ON sizes.list_id = l.id
             JOIN list_movies lm ON lm.list_id = l.id JOIN movies m ON m.id = lm.movie_id
             WHERE l.user_id = $1 AND sizes.n >= 5 AND m.tmdb_id = ANY($2::text[])
             ORDER BY lm.rank::float / sizes.n, lm.rank
             LIMIT 1`,
            [user_id, films.map((f) => String(f.tmdb_id))]
        );
        const row = best.rows[0];
        if (row) {
            newFavourite = { ...films.find((f) => f.tmdb_id === row.tmdb_id), rank: row.rank, list_name: row.list_name };
        }
    }

    return {
        year,
        years,
        films_watched: films.length,
        rewatches: watches.length - films.length,
        total_watches: watches.length,
        // Watches per month, January first, and the busiest month (1 to 12)
        months,
        busiest_month: busiest > 0 ? months.indexOf(busiest) + 1 : null,
        first_film: watches.length ? film(watches[0]) : null,
        latest_film: watches.length ? film(watches[watches.length - 1]) : null,
        most_rewatched: rewatchedCount >= 2 ? { ...films.find((f) => f.tmdb_id === rewatchedId), times: rewatchedCount } : null,
        new_favourite: newFavourite,
        closest_friend: await closestFriend(user_id),
        films,
    };
}

module.exports = { yearReview, closestFriend };
