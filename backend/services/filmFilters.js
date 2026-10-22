const axios = require("axios");
const { tmdbPath } = require("./tmdbMedia");

// Language and streaming filters for recommendations. Languages are TMDb's original_language codes ("en",
// "ko"); streaming services are TMDb provider ids, which differ by country, so a region always goes with them

const DAY = 24 * 60 * 60 * 1000;
// Which services stream each film, by "tmdbId:region", for a day: availability changes slowly, and one
// Discover batch can ask about dozens of films
const streamingCache = new Map();
// The services available in each country, for the filter picker
const servicesCache = new Map();

/// Cleans filter values from a request: up to 10 two-letter language codes, up to 20 provider ids, and a
/// two-letter region (US when missing)
function parseFilters({ languages, providers, region }) {
    const list = (value) => (Array.isArray(value) ? value : String(value ?? "").split(",")).map((item) => String(item).trim()).filter(Boolean);
    return {
        languages: list(languages).map((code) => code.toLowerCase()).filter((code) => /^[a-z]{2}$/.test(code)).slice(0, 10),
        providers: list(providers).map(Number).filter((id) => Number.isInteger(id) && id > 0).slice(0, 20),
        region: /^[A-Za-z]{2}$/.test(String(region ?? "")) ? String(region).toUpperCase() : "US",
    };
}

const hasFilters = (filters) => filters.languages.length > 0 || filters.providers.length > 0;

/// The ids of the services streaming a film in a region, free ones (with or without ads) included
async function streamingServices(tmdbId, region) {
    const key = `${tmdbId}:${region}`;
    const cached = streamingCache.get(key);
    if (cached && Date.now() - cached.at < DAY) return cached.ids;
    let ids = new Set();
    try {
        const response = await axios.get(`https://api.themoviedb.org/3/${tmdbPath(tmdbId)}/watch/providers`, {
            params: { api_key: process.env.API_KEY },
            timeout: 15000,
        });
        const country = response.data.results?.[region] ?? {};
        ids = new Set([...(country.flatrate ?? []), ...(country.free ?? []), ...(country.ads ?? [])].map((item) => item.provider_id));
    } catch (error) {
        // An unknown film streams nowhere; anything else is left uncached so it's tried again
        if (error.response?.status !== 404) return ids;
    }
    streamingCache.set(key, { at: Date.now(), ids });
    return ids;
}

/// Whether a film passes the filters: in one of the chosen languages, and streaming on one of the chosen services
async function matchesFilters(movie, filters) {
    if (filters.languages.length && !filters.languages.includes(movie.original_language)) return false;
    if (filters.providers.length) {
        const services = await streamingServices(movie.id, filters.region);
        if (!filters.providers.some((id) => services.has(id))) return false;
    }
    return true;
}

/// The streaming services most used in a country, most popular first, for the filter picker
async function availableServices(region) {
    const cached = servicesCache.get(region);
    if (cached && Date.now() - cached.at < DAY) return cached.services;
    const response = await axios.get("https://api.themoviedb.org/3/watch/providers/movie", {
        params: { api_key: process.env.API_KEY, watch_region: region, language: "en-US" },
        timeout: 15000,
    });
    const services = (response.data.results ?? [])
        .sort((a, b) => (a.display_priorities?.[region] ?? a.display_priority ?? 999) - (b.display_priorities?.[region] ?? b.display_priority ?? 999))
        // Stores sell or rent films rather than stream them, so they can't satisfy the filter
        .filter((item) => !/store|amazon video|google play|youtube|microsoft|vudu|fandango|cineplex/i.test(item.provider_name))
        .slice(0, 30)
        .map((item) => ({ id: item.provider_id, name: item.provider_name, logo_path: item.logo_path ?? null }));
    servicesCache.set(region, { at: Date.now(), services });
    return services;
}

module.exports = { parseFilters, hasFilters, matchesFilters, availableServices, streamingServices };
