// "More Like This": films like one film (or show), from TMDb's recommendations for it, topped up with TMDb's
// similar titles when the recommendations are thin (obscure films often have few or none). Films already in the
// user's lists and the film itself are left out, so everything shown is something new to add

const { isTV, tmdbPath, showAsFilm } = require("./tmdbMedia");

// Enough to fill a screen and scroll a little, without asking TMDb for more pages than needed
const MAX_FILMS = 40;
// With fewer new films than this from the recommendations, TMDb's similar titles are added after them
const ENOUGH = 20;

/// The films like `id`, best match first, in the shape `toMovie` gives (null drops a film). `get(path, params)`
/// returns a TMDb answer (cached by the caller); `listed` is a Set of the TMDb ids in the user's lists
async function similarFilms(id, { get, listed = new Set(), toMovie }) {
    const tv = isTV(id);
    const page = async (kind, number) => {
        try {
            const data = await get(`${tmdbPath(id)}/${kind}`, { language: "en-US", page: number });
            return (data.results ?? []).map((item) => (tv ? showAsFilm(item) : item));
        } catch (error) {
            // A film TMDb doesn't know about has no recommendations, rather than failing the screen
            if (error.response?.status === 404) return [];
            throw error;
        }
    };

    const seen = new Set([Number(id)]);
    const films = [];
    const addAll = (results) => {
        for (const result of results) {
            const film = toMovie(result);
            if (!film || seen.has(film.id)) continue;
            seen.add(film.id);
            if (!listed.has(Number(film.id))) films.push(film);
        }
    };

    const recommended = await Promise.all([page("recommendations", 1), page("recommendations", 2)]);
    recommended.forEach(addAll);
    if (films.length < ENOUGH) {
        addAll(await page("similar", 1));
    }
    return films.slice(0, MAX_FILMS);
}

module.exports = { similarFilms, MAX_FILMS, ENOUGH };
