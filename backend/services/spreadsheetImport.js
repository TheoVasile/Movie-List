// Spreadsheet imports arrive in batches so the app can show progress on long sheets and no single request
// runs for minutes
const MAX_BATCH = 50;

const MAX_TITLE = 300;
const MAX_NOTE = 5000;

// A "YYYY-MM-DD" day that exists and isn't in the future, or null
function cleanDate(value) {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
    const date = new Date(`${value}T00:00:00Z`);
    if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) return null;
    if (date.getUTCFullYear() < 1870 || date.getTime() > Date.now() + 24 * 60 * 60 * 1000) return null;
    return value;
}

// Keeps only the fields the import uses, in the shapes it expects, and drops rows without a title.
// The app has already read the sheet, so this is a guard against bad input rather than a parser
function cleanFilms(films) {
    return films
        .filter((film) => film && typeof film.name === "string" && film.name.trim())
        .map((film) => {
            const year = Number(film.year);
            const watchedOn = cleanDate(film.watched_on);
            return {
                name: film.name.trim().slice(0, MAX_TITLE),
                year: Number.isInteger(year) && year >= 1870 && year <= 2100 ? year : null,
                watched_on: watchedOn,
                watched: watchedOn !== null || film.watched === true,
                note: typeof film.note === "string" ? film.note.trim().slice(0, MAX_NOTE) : "",
            };
        });
}

module.exports = { MAX_BATCH, cleanFilms, cleanDate };
