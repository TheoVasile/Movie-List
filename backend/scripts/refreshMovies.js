const pool = require("../config/db");
const { fetchTmdb } = require("../services/tmdbCache");
const { tmdbPath } = require("../services/tmdbMedia");
const { movieFields } = require("../models/movieModel");

// Replaces saved films' titles, posters and overviews with TMDb's, for films whose copy didn't come from TMDb.
// Films used to be saved with whatever the app sent, and are still saved from the app's copy when TMDb can't be
// reached (metadata_source 'client'; see ensureMovie in models/movieModel.js). Run by hand from backend/, against
// a database you mean to change (DATABASE_URL and API_KEY from .env):
//
//     node scripts/refreshMovies.js               lists what would be refreshed, changes nothing
//     node scripts/refreshMovies.js --apply       refreshes them from TMDb
//
// Which films: every one marked 'client', and those saved before metadata_source was kept (null: unknown) whose
// title, overview or poster is blank. --all-unknown takes every unknown film instead, to also replace copies that
// look fine but came from the app. Films marked 'tmdb' are left alone. Each refreshed film is marked 'tmdb'.
// Other options: --limit=500 (at most this many films a run), --delay=250 (milliseconds between TMDb requests,
// to stay well under TMDb's rate limit while the server is using it too)

const APPLY = process.argv.includes("--apply");
const ALL_UNKNOWN = process.argv.includes("--all-unknown");
const option = (name, fallback) => {
    const value = Number(process.argv.find((arg) => arg.startsWith(`--${name}=`))?.split("=")[1]);
    return Number.isFinite(value) && value >= 0 ? value : fallback;
};
const LIMIT = option("limit", 100000);
const DELAY = option("delay", 250);

const blank = (column) => `COALESCE(TRIM(${column}), '') = ''`;

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function refresh() {
    const rows = (await pool.query(
        `SELECT id, tmdb_id, metadata_source FROM movies
         WHERE metadata_source = 'client'
            OR (metadata_source IS NULL AND ($1 OR ${blank("title")} OR ${blank("overview")} OR ${blank("poster_path")}))
         ORDER BY id LIMIT $2`,
        [ALL_UNKNOWN, LIMIT]
    )).rows;
    console.log(`${rows.length} films to refresh${APPLY ? "" : " (dry run: add --apply to change them)"}`);
    if (!APPLY) {
        const bySource = {};
        for (const row of rows) bySource[row.metadata_source ?? "unknown"] = (bySource[row.metadata_source ?? "unknown"] ?? 0) + 1;
        console.log(bySource);
        return;
    }
    let refreshed = 0, missing = 0, failed = 0;
    for (const row of rows) {
        try {
            const tmdb = await fetchTmdb(tmdbPath(row.tmdb_id));
            const film = movieFields({ ...tmdb, title: tmdb.title ?? tmdb.name, release_date: tmdb.release_date ?? tmdb.first_air_date });
            if (!film) {
                missing++;
            } else {
                await pool.query(
                    `UPDATE movies SET title = $2, release_date = $3, overview = $4, poster_path = $5, original_language = $6,
                            popularity = $7, metadata_source = 'tmdb'
                     WHERE id = $1`,
                    [row.id, film.title, film.release_date, film.overview, film.poster_path, film.original_language, film.popularity]
                );
                refreshed++;
            }
        } catch (error) {
            // A film TMDb no longer has keeps its copy; anything else (TMDb down) is tried again next run
            if (error.response?.status === 404) missing++;
            else failed++;
            console.warn(`movies.id ${row.id} (${tmdbPath(row.tmdb_id)}): ${error.message}`);
        }
        await wait(DELAY);
    }
    console.log(`Refreshed ${refreshed}; ${missing} not on TMDb; ${failed} failed and will be tried next run`);
}

refresh()
    .then(() => pool.end())
    .catch((error) => {
        console.error("Refreshing films failed:", error);
        pool.end(() => process.exit(1));
    });
