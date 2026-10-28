const axios = require("axios");
const pool = require("../config/db");

// Every TMDb request goes through here. Answers worth keeping are cached in two layers: a small one in this server's
// memory (the most recently used TMDB_MEMORY_CACHE_SIZE answers), and the tmdb_cache table, which every server shares
// and which survives restarts and deploys. TMDb allows around 50 requests a second, so without this a launch spike
// of searches and Discover swipes would soon be turned away

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const MEMORY_MAX = Number(process.env.TMDB_MEMORY_CACHE_SIZE) || 2000;
// key -> { value, expiresAt }, least recently used first
const memory = new Map();
// Loads under way, so a burst of the same request waits for one answer instead of asking TMDb many times
const loading = new Map();

function remember(key, value, expiresAt) {
    memory.delete(key);
    memory.set(key, { value, expiresAt });
    if (memory.size > MEMORY_MAX) memory.delete(memory.keys().next().value);
}

function fromMemory(key) {
    const hit = memory.get(key);
    if (!hit) return undefined;
    if (hit.expiresAt <= Date.now()) {
        memory.delete(key);
        return undefined;
    }
    // Moved to the end, as the most recently used
    memory.delete(key);
    memory.set(key, hit);
    return hit.value;
}

// Expired rows are deleted every so often by whichever request happens to save something, rather than on a timer
let lastSweep = 0;
function sweepExpired() {
    if (Date.now() - lastSweep < 10 * MINUTE) return;
    lastSweep = Date.now();
    pool.query("DELETE FROM tmdb_cache WHERE expires_at < NOW()")
        .catch((error) => console.error("Couldn't delete expired TMDb answers:", error.message));
}

/// The value saved under key if it's younger than maxAge, otherwise load()'s, which is then saved. Values must be
/// JSON. A failed load isn't saved, so it's tried again next time. If the database can't be reached, TMDb is asked
/// directly. onHit, if given, is called when the answer came from a cache
async function cached(key, maxAge, load, onHit = () => {}) {
    const hit = fromMemory(key);
    if (hit !== undefined) {
        onHit("memory");
        return hit;
    }
    if (loading.has(key)) return loading.get(key);
    const promise = (async () => {
        try {
            const row = (await pool.query("SELECT body, expires_at FROM tmdb_cache WHERE key = $1 AND expires_at > NOW()", [key])).rows[0];
            if (row) {
                remember(key, row.body, row.expires_at.getTime());
                onHit("database");
                return row.body;
            }
        } catch (error) {
            console.error("Couldn't read the TMDb cache:", error.message);
        }
        const value = await load();
        const expiresAt = Date.now() + maxAge;
        remember(key, value, expiresAt);
        pool.query(
            `INSERT INTO tmdb_cache (key, body, expires_at) VALUES ($1, $2, $3)
             ON CONFLICT (key) DO UPDATE SET body = $2, expires_at = $3`,
            [key, JSON.stringify(value), new Date(expiresAt)]
        ).catch((error) => console.error("Couldn't save to the TMDb cache:", error.message));
        sweepExpired();
        return value;
    })().finally(() => loading.delete(key));
    loading.set(key, promise);
    return promise;
}

/// cached() for many keys at once, with one database read for all of them and one write for everything loaded, so
/// describing a hundred films doesn't take a hundred database connections. load(key) gives a missing key's value (a
/// failed load leaves the key out); at most `concurrency` loads run at once. Returns a Map key -> value
async function cachedMany(keys, maxAge, load, concurrency = 10) {
    const found = new Map();
    let missing = [];
    for (const key of new Set(keys)) {
        const hit = fromMemory(key);
        if (hit !== undefined) found.set(key, hit);
        else missing.push(key);
    }
    if (missing.length) {
        try {
            const rows = (await pool.query("SELECT key, body, expires_at FROM tmdb_cache WHERE key = ANY($1) AND expires_at > NOW()", [missing])).rows;
            for (const row of rows) {
                remember(row.key, row.body, row.expires_at.getTime());
                found.set(row.key, row.body);
            }
            missing = missing.filter((key) => !found.has(key));
        } catch (error) {
            console.error("Couldn't read the TMDb cache:", error.message);
        }
    }
    const loaded = [];
    let next = 0;
    const worker = async () => {
        while (next < missing.length) {
            const key = missing[next++];
            try {
                const value = await load(key);
                remember(key, value, Date.now() + maxAge);
                found.set(key, value);
                loaded.push(key);
            } catch (error) {
                // Left out, and tried again next time
            }
        }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, missing.length) }, worker));
    if (loaded.length) {
        pool.query(
            `INSERT INTO tmdb_cache (key, body, expires_at)
             SELECT * FROM unnest($1::text[], $2::jsonb[], $3::timestamptz[])
             ON CONFLICT (key) DO UPDATE SET body = EXCLUDED.body, expires_at = EXCLUDED.expires_at`,
            [loaded, loaded.map((key) => JSON.stringify(found.get(key))), loaded.map(() => new Date(Date.now() + maxAge))]
        ).catch((error) => console.error("Couldn't save to the TMDb cache:", error.message));
        sweepExpired();
    }
    return found;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/// TMDb's answer (response.data) for a path such as "movie/771", with the API key added. When TMDb says there are
/// too many requests (429) it's asked once more, after the wait it gives (at most 10 seconds). Other failures throw
/// axios's error, so error.response?.status still tells a missing film (404) apart
async function fetchTmdb(path, params = {}) {
    const request = () => axios.get(`https://api.themoviedb.org/3/${path}`, {
        params: { ...params, api_key: process.env.API_KEY },
        timeout: 15000,
    });
    try {
        return (await request()).data;
    } catch (error) {
        if (error.response?.status !== 429) throw error;
        const seconds = Math.min(Math.max(Number(error.response.headers?.["retry-after"]) || 1, 1), 10);
        console.warn(`TMDb is rate limiting us; trying ${path} again in ${seconds}s`);
        await wait(seconds * 1000);
        return (await request()).data;
    }
}

/// fetchTmdb, cached for maxAge when it's given. Only for answers that are small and asked for again, such as a
/// page of Discover results; for big ones (a film's full details) cache just the part that's used, with cached()
async function tmdbGet(path, params = {}, maxAge = 0) {
    if (!maxAge) return fetchTmdb(path, params);
    const query = Object.keys(params).sort().map((key) => `${key}=${params[key]}`).join("&");
    return cached(`get:${path}?${query}`, maxAge, () => fetchTmdb(path, params));
}

module.exports = { cached, cachedMany, tmdbGet, fetchTmdb, MINUTE, HOUR, DAY };
