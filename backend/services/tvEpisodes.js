const pool = require("../config/db");
const { notifyUser } = require("./pushService");
const { cached, fetchTmdb, HOUR: HOURS } = require("./tmdbCache");
const { mapWithConcurrency } = require("./letterboxdService");

// TV episode tracking: a show's seasons and episodes from TMDb, which episodes each person has watched, and a
// daily push when a new season of a show in someone's lists starts. Shows are stored by their positive TMDb id;
// the app's negative TV ids (services/tmdbMedia.js) are turned around on the way in

// Shows checked at once by the daily new-season alerts, and alerts sent at once
const CONCURRENCY = 6;

const episodeRef = (episode) => episode
    ? { season: episode.season_number, episode: episode.episode_number, name: episode.name ?? "", air_date: episode.air_date ?? "" }
    : null;

/// A show's seasons (specials left out), its latest aired and next episode, and its status, e.g. "Returning Series"
async function showDetails(showId) {
    return cached(`show:${showId}`, 6 * HOURS, async () => {
        const show = await fetchTmdb(`tv/${showId}`);
        return {
            name: show.name ?? "",
            status: show.status ?? "",
            seasons: (show.seasons ?? [])
                .filter((season) => season.season_number > 0)
                .map((season) => ({
                    season: season.season_number,
                    name: season.name ?? `Season ${season.season_number}`,
                    episodes: season.episode_count ?? 0,
                    air_date: season.air_date ?? "",
                    poster_path: season.poster_path ?? null,
                })),
            last_episode: episodeRef(show.last_episode_to_air),
            next_episode: episodeRef(show.next_episode_to_air),
        };
    });
}

/// One season's episodes in order
async function seasonEpisodes(showId, season) {
    return cached(`season:${showId}:${season}`, 6 * HOURS, async () => {
        const data = await fetchTmdb(`tv/${showId}/season/${season}`);
        return {
            season,
            name: data.name ?? `Season ${season}`,
            episodes: (data.episodes ?? []).map((episode) => ({
                episode: episode.episode_number,
                name: episode.name ?? "",
                air_date: episode.air_date ?? "",
                runtime: episode.runtime ?? 0,
                overview: episode.overview ?? "",
                still_path: episode.still_path ?? null,
            })),
        };
    });
}

/// The episodes of a show the user has watched, as [{ season, episode }] in order
async function watchedEpisodes(user_id, showId) {
    const result = await pool.query(
        "SELECT season, episode FROM episode_watches WHERE user_id = $1 AND show_id = $2 ORDER BY season, episode",
        [user_id, showId]
    );
    return result.rows;
}

/// Marks episodes of one season watched or not, then returns everything watched in the show
async function setEpisodesWatched(user_id, showId, season, episodes, watched) {
    if (watched) {
        await pool.query(
            `INSERT INTO episode_watches (user_id, show_id, season, episode)
             SELECT $1, $2, $3, unnest($4::int[]) ON CONFLICT DO NOTHING`,
            [user_id, showId, season, episodes]
        );
    } else {
        await pool.query(
            "DELETE FROM episode_watches WHERE user_id = $1 AND show_id = $2 AND season = $3 AND episode = ANY($4::int[])",
            [user_id, showId, season, episodes]
        );
    }
    return watchedEpisodes(user_id, showId);
}

/// Whether a season of a show starts today, or started in the last couple of days (the daily run may have
/// missed it): the season number and whether it's today, or null
function premiere(show, today) {
    const next = show.next_episode;
    if (next && next.episode === 1 && next.air_date === today) return { season: next.season, today: true };
    const last = show.last_episode;
    if (last && last.episode === 1 && last.air_date && last.air_date <= today) {
        const days = (new Date(today) - new Date(last.air_date)) / (24 * HOURS);
        if (days <= 2) return { season: last.season, today: days === 0 };
    }
    return null;
}

/// Once a day: tells people when a new season of a show in any of their lists starts. Each season is announced
/// once per person. Uses the Now Streaming notification setting
async function sendSeasonAlerts() {
    const rows = (await pool.query(
        `SELECT DISTINCT u.firebase_uid, (-m.tmdb_id::int) AS show_id, m.title
         FROM users u
         JOIN device_tokens t ON t.user_id = u.firebase_uid
         JOIN lists l ON l.user_id = u.firebase_uid
         JOIN list_movies lm ON lm.list_id = l.id
         JOIN movies m ON m.id = lm.movie_id
         WHERE u.notify_streaming AND m.tmdb_id ~ '^-[0-9]+$'`
    )).rows;
    const today = new Date().toISOString().slice(0, 10);
    const premieres = new Map();
    await mapWithConcurrency([...new Set(rows.map((row) => row.show_id))], async (showId) => {
        try {
            const found = premiere(await showDetails(showId), today);
            if (found) premieres.set(showId, found);
        } catch (error) {
            console.error(`Couldn't check show ${showId}:`, error.message);
        }
    }, CONCURRENCY);
    const due = rows.filter((row) => premieres.has(row.show_id));
    if (!due.length) return { shows: premieres.size, sent: 0 };
    // Every alert due is recorded in one query, which returns the ones not sent before
    const fresh = await pool.query(
        `INSERT INTO season_alerts_sent (user_id, show_id, season)
         SELECT unnest($1::text[]), unnest($2::int[]), unnest($3::int[]) ON CONFLICT DO NOTHING
         RETURNING user_id, show_id`,
        [due.map((row) => row.firebase_uid), due.map((row) => row.show_id), due.map((row) => premieres.get(row.show_id).season)]
    );
    const isFresh = new Set(fresh.rows.map((row) => `${row.user_id}:${row.show_id}`));
    // delete() is true only the first time, so a show listed under two titles is announced once
    const sent = await mapWithConcurrency(due.filter((row) => isFresh.delete(`${row.firebase_uid}:${row.show_id}`)), async (row) => {
        const found = premieres.get(row.show_id);
        const when = found.today ? "starts today" : "is out now";
        return await notifyUser(row.firebase_uid, "streaming", {
            title: found.season === 1 ? row.title : "New season",
            body: found.season === 1 ? `${row.title} ${when}` : `Season ${found.season} of ${row.title} ${when}`,
            data: { tmdb_id: String(-row.show_id) },
        }) > 0 ? 1 : 0;
    }, CONCURRENCY);
    return { shows: premieres.size, sent: sent.reduce((sum, n) => sum + n, 0) };
}

module.exports = { showDetails, seasonEpisodes, watchedEpisodes, setEpisodesWatched, sendSeasonAlerts, premiere };
