const pool = require("../config/db");
const { streamingServices, availableServices } = require("./filmFilters");
const { notifyUser } = require("./pushService");
const { mapWithConcurrency } = require("./letterboxdService");

// "It's streaming now" alerts: once a day, films on people's watchlists that just started streaming on one of
// their services, or that come out today. A watchlist is any of their lists with "watch" in its name, as on
// the phone, and only films they haven't watched count.
//
// What each film streams on is remembered per country (film_availability), so only changes cause alerts. The
// first time a film is seen there's nothing to compare with, so it's only remembered: otherwise the first run
// would announce everything already streaming

// Per person, so someone with a huge watchlist can't make the daily run slow for everyone
const MAX_FILMS_PER_PERSON = 150;
// TMDb lookups, and people alerted, at once
const CONCURRENCY = 6;

/// Saves which services the user has and in which country, and whether they want these alerts. Fields left
/// undefined keep their current value. Unknown service ids are dropped
async function setStreamingPreferences(user_id, { region, services, notify }) {
    await pool.query(
        `UPDATE users SET streaming_region = COALESCE($2, streaming_region),
                          streaming_services = COALESCE($3::int[], streaming_services),
                          notify_streaming = COALESCE($4, notify_streaming)
         WHERE firebase_uid = $1`,
        [user_id, region ?? null, services ?? null, typeof notify === "boolean" ? notify : null]
    );
}

/// The user's settings, with their services' names
async function streamingPreferences(user_id) {
    const result = await pool.query(
        "SELECT streaming_region, streaming_services, notify_streaming FROM users WHERE firebase_uid = $1",
        [user_id]
    );
    const row = result.rows[0];
    if (!row) return null;
    return { region: row.streaming_region, services: row.streaming_services ?? [], notify: row.notify_streaming };
}

// Films whose availability is saved per query
const SAVE_CHUNK = 500;

/// Which of the films in a country gained services since they were last checked, as Map(tmdbId -> [service ids])
async function newArrivals(region, tmdbIds) {
    const known = await pool.query(
        "SELECT tmdb_id, providers FROM film_availability WHERE region = $1 AND tmdb_id = ANY($2::int[])",
        [region, tmdbIds]
    );
    const before = new Map(known.rows.map((row) => [row.tmdb_id, new Set(row.providers)]));
    const arrivals = new Map();
    const checked = await mapWithConcurrency(tmdbIds, async (tmdbId) => {
        const now = [...(await streamingServices(tmdbId, region))];
        const previous = before.get(tmdbId);
        if (previous) {
            const added = now.filter((id) => !previous.has(id));
            if (added.length) arrivals.set(tmdbId, added);
        }
        return { id: tmdbId, providers: now };
    }, CONCURRENCY);
    // Saved a few hundred films per query rather than one at a time
    for (let i = 0; i < checked.length; i += SAVE_CHUNK) {
        await pool.query(
            `INSERT INTO film_availability (tmdb_id, region, providers, checked_at)
             SELECT (film->>'id')::int, $1, ARRAY(SELECT jsonb_array_elements_text(film->'providers')::int), CURRENT_TIMESTAMP
             FROM jsonb_array_elements($2::jsonb) film
             ON CONFLICT (tmdb_id, region) DO UPDATE SET providers = EXCLUDED.providers, checked_at = CURRENT_TIMESTAMP`,
            [region, JSON.stringify(checked.slice(i, i + SAVE_CHUNK))]
        );
    }
    return arrivals;
}

/// "Past Lives is now on Netflix", or a summary when there's more than one
function describe(items) {
    const line = (item) => (item.service ? `${item.title} is now on ${item.service}` : `${item.title} is out today`);
    if (items.length === 1) {
        return { title: items[0].service ? "Now streaming 🍿" : "Out today 🎬", body: `${line(items[0])}.` };
    }
    const shown = items.slice(0, 3).map(line).join(", ");
    const more = items.length > 3 ? `, and ${items.length - 3} more` : "";
    return { title: `${items.length} films from your watchlist are ready to watch`, body: `${shown}${more}.` };
}

/// Sends the day's alerts. Returns how many people were checked and sent one. userIds limits it to those
/// accounts, for trying it out without alerting anyone else
async function sendStreamingAlerts({ userIds = null } = {}) {
    const people = (await pool.query(
        `SELECT DISTINCT u.firebase_uid, COALESCE(u.streaming_region, 'US') AS region, u.streaming_services
         FROM users u JOIN device_tokens t ON t.user_id = u.firebase_uid
         WHERE u.notify_streaming AND (u.last_streaming_alert_at IS NULL OR u.last_streaming_alert_at < NOW() - INTERVAL '20 hours')
           AND ($1::text[] IS NULL OR u.firebase_uid = ANY($1::text[]))`,
        [userIds]
    )).rows;
    if (!people.length) return { candidates: 0, sent: 0 };

    // Everyone's unwatched watchlist films, with today's releases marked, in one query rather than one per person
    const watchlists = new Map(people.map((person) => [person.firebase_uid, []]));
    const films = await pool.query(
        `SELECT user_id, tmdb_id, title, out_today FROM (
             SELECT f.*, ROW_NUMBER() OVER (PARTITION BY f.user_id ORDER BY f.tmdb_key) AS n FROM (
                 SELECT DISTINCT ON (l.user_id, m.tmdb_id) l.user_id, m.tmdb_id AS tmdb_key, m.tmdb_id::int AS tmdb_id, m.title,
                        m.release_date = to_char(CURRENT_DATE, 'YYYY-MM-DD') AS out_today
                 FROM lists l JOIN list_movies lm ON lm.list_id = l.id JOIN movies m ON m.id = lm.movie_id
                 WHERE l.user_id = ANY($1::text[]) AND l.name ILIKE '%watch%' AND m.tmdb_id ~ '^[0-9]+$'
                   AND NOT EXISTS (SELECT 1 FROM watched_movies w WHERE w.user_id = l.user_id AND w.movie_id = m.id)
                 ORDER BY l.user_id, m.tmdb_id, lm.rank
             ) f
         ) numbered
         WHERE n <= $2`,
        [people.map((person) => person.firebase_uid), MAX_FILMS_PER_PERSON]
    );
    for (const { user_id, ...film } of films.rows) watchlists.get(user_id).push(film);

    // Availability changes, checked once per film and country however many people have it
    const arrivalsByRegion = new Map();
    for (const region of new Set(people.filter((p) => p.streaming_services?.length).map((p) => p.region))) {
        const ids = [...new Set(people.filter((p) => p.region === region && p.streaming_services?.length)
            .flatMap((p) => watchlists.get(p.firebase_uid).map((film) => film.tmdb_id)))];
        arrivalsByRegion.set(region, ids.length ? await newArrivals(region, ids) : new Map());
    }

    let sent = 0;
    // What each person was told, for the response
    const found = [];
    // A few people at a time, since each alert waits on Firebase
    await mapWithConcurrency(people, async (person) => {
        try {
            const mine = new Set(person.streaming_services ?? []);
            const arrivals = arrivalsByRegion.get(person.region) ?? new Map();
            const names = mine.size ? new Map((await availableServices(person.region)).map((s) => [s.id, s.name])) : new Map();
            const watchlist = watchlists.get(person.firebase_uid);
            const arrived = watchlist
                .map((film) => ({ film, service: (arrivals.get(film.tmdb_id) ?? []).find((id) => mine.has(id)) }))
                .filter(({ service }) => service !== undefined);
            // Each film and service is announced once, even if it leaves and comes back. All of this person's are
            // recorded in one query, which returns the ones not announced before
            const fresh = new Set();
            if (arrived.length) {
                const inserted = await pool.query(
                    `INSERT INTO streaming_alerts_sent (user_id, tmdb_id, provider_id)
                     SELECT $1, unnest($2::int[]), unnest($3::int[]) ON CONFLICT DO NOTHING RETURNING tmdb_id`,
                    [person.firebase_uid, arrived.map(({ film }) => film.tmdb_id), arrived.map(({ service }) => service)]
                );
                inserted.rows.forEach((row) => fresh.add(row.tmdb_id));
            }
            const items = [];
            for (const film of watchlist) {
                const service = (arrivals.get(film.tmdb_id) ?? []).find((id) => mine.has(id));
                if (service !== undefined) {
                    if (fresh.has(film.tmdb_id)) items.push({ tmdbId: film.tmdb_id, title: film.title, service: names.get(service) ?? "one of your services" });
                } else if (film.out_today) {
                    items.push({ tmdbId: film.tmdb_id, title: film.title, service: null });
                }
            }
            if (!items.length) return;
            found.push({ user_id: person.firebase_uid, ...describe(items) });
            const message = describe(items);
            // One film opens straight to it
            const data = items.length === 1 ? { tmdb_id: String(items[0].tmdbId) } : {};
            if (await notifyUser(person.firebase_uid, "streaming", { ...message, data })) {
                sent++;
                await pool.query("UPDATE users SET last_streaming_alert_at = NOW() WHERE firebase_uid = $1", [person.firebase_uid]);
            }
        } catch (error) {
            console.error("Couldn't send a streaming alert:", error.message);
        }
    }, CONCURRENCY);
    return { candidates: people.length, sent, alerts: userIds ? found : found.length };
}

module.exports = { sendStreamingAlerts, setStreamingPreferences, streamingPreferences, newArrivals, describe };
