const axios = require("axios");

const CONCURRENCY = 5;

// Runs fn over items with a fixed number of requests in flight, preserving order
async function mapWithConcurrency(items, fn) {
    const results = new Array(items.length);
    let nextIndex = 0;
    const workers = Array.from({ length: Math.min(CONCURRENCY, items.length) }, async () => {
        while (nextIndex < items.length) {
            const index = nextIndex++;
            results[index] = await fn(items[index], index);
        }
    });
    await Promise.all(workers);
    return results;
}

function normalizeTitle(title) {
    return (title ?? "")
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .toLowerCase()
        .replace(/&/g, "and")
        .replace(/[^a-z0-9]/g, "");
}

async function searchTmdb(name, params) {
    const response = await axios.get("https://api.themoviedb.org/3/search/movie", {
        params: { query: name, include_adult: false, language: "en-US", api_key: process.env.API_KEY, ...params },
        timeout: 15000,
    });
    return response.data.results ?? [];
}

// Letterboxd exports only carry a title and year, so prefer an exact title match within that year,
// widening the year by one either side for festival vs. theatrical release differences
async function matchFilm({ name, year }) {
    const target = normalizeTitle(name);
    const isMatch = (movie) => normalizeTitle(movie.title) === target || normalizeTitle(movie.original_title) === target;
    const releaseYear = (movie) => Number((movie.release_date ?? "").slice(0, 4));

    if (year) {
        const sameYear = await searchTmdb(name, { primary_release_year: year });
        const exact = sameYear.find(isMatch);
        if (exact) return exact;

        const nearby = await searchTmdb(name);
        const close = nearby.find((movie) => isMatch(movie) && Math.abs(releaseYear(movie) - year) <= 1);
        return close ?? sameYear[0] ?? null;
    }

    const results = await searchTmdb(name);
    return results.find(isMatch) ?? results[0] ?? null;
}

// Resolves every film in a list to a TMDb movie, reporting the ones that couldn't be matched
async function resolveFilms(films) {
    const resolved = await mapWithConcurrency(films, async (film) => {
        try {
            return await matchFilm(film);
        } catch (error) {
            console.error(`Failed to match Letterboxd film ${film.name} (${film.year}):`, error.message);
            return null;
        }
    });
    return {
        movies: resolved.filter(Boolean),
        skipped: films.filter((_, i) => !resolved[i]).map((film) => film.year ? `${film.name} (${film.year})` : film.name),
    };
}

module.exports = { resolveFilms, mapWithConcurrency };
