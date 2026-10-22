// Films and TV shows share one movies table and one set of routes. TMDb's film and TV ids overlap, so a TV
// show's id is stored and sent as the negative of its TMDb id: -1399 is the show with TMDb id 1399 (Game of
// Thrones), while 1399 is a film. Everything that calls TMDb with an id goes through tmdbPath

const isTV = (id) => Number(id) < 0;

/// The TMDb path for a film or show, e.g. 771 -> "movie/771", -1399 -> "tv/1399"
function tmdbPath(id) {
    const number = Number(id);
    return number < 0 ? `tv/${-number}` : `movie/${number}`;
}

// TV genres TMDb has no film genre for, as the film genres they're closest to, so the taste profile and genre
// filters (built on film genres) work for shows too. Genres both share keep their ids
const TV_GENRES_AS_FILM = {
    10759: [28, 12], // Action & Adventure
    10762: [10751], // Kids -> Family
    10765: [878, 14], // Sci-Fi & Fantasy
    10768: [10752], // War & Politics -> War
};
// The other way, for asking TMDb for shows in film genres
const FILM_GENRES_AS_TV = { 28: 10759, 12: 10759, 878: 10765, 14: 10765, 10752: 10768 };

function filmGenres(tvGenreIds = []) {
    return [...new Set(tvGenreIds.flatMap((id) => TV_GENRES_AS_FILM[id] ?? [id]))];
}

function tvGenres(filmGenreIds = []) {
    return [...new Set(filmGenreIds.map((id) => FILM_GENRES_AS_TV[id] ?? id))];
}

/// A TMDb TV result in the shape of a film result: negative id, name as title, first air date as release date
/// and film genres, with media_type "tv" so the app can label it
function showAsFilm(show) {
    return {
        ...show,
        id: -show.id,
        title: show.name,
        original_title: show.original_name,
        release_date: show.first_air_date ?? "",
        genre_ids: filmGenres(show.genre_ids ?? (show.genres ?? []).map((genre) => genre.id)),
        media_type: "tv",
    };
}

module.exports = { isTV, tmdbPath, showAsFilm, filmGenres, tvGenres };
