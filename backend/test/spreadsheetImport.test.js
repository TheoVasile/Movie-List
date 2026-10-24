const test = require("node:test");
const assert = require("node:assert");
const Module = require("module");
const searches = require("./fixtures/tmdbSearch.json");

// TMDb search answered from the fixture instead of the network, honouring primary_release_year like TMDb does
const fakeAxios = {
    get: async (url, { params }) => {
        const results = (searches[params.query] ?? []).filter((movie) =>
            !params.primary_release_year || movie.release_date.startsWith(String(params.primary_release_year)));
        return { data: { results } };
    },
};
const load = Module._load;
Module._load = function (request, ...rest) {
    return request === "axios" ? fakeAxios : load.call(this, request, ...rest);
};

const { matchFilms, describeFilm } = require("../services/letterboxdService");
const { cleanFilms, cleanDate } = require("../services/spreadsheetImport");

test("cleanFilms keeps the fields the import uses and drops rows without a title", () => {
    const films = cleanFilms([
        { name: "  Heat ", year: "1995", watched_on: "2024-02-29", note: " Great " },
        { name: "", year: 2000 },
        null,
        { name: "Amelie", year: 3000, watched: true, watched_on: "2023-02-30" },
        { name: "Crouching Tiger, Hidden Dragon", note: 5 },
    ]);
    assert.deepStrictEqual(films, [
        { name: "Heat", year: 1995, watched_on: "2024-02-29", watched: true, note: "Great" },
        { name: "Amelie", year: null, watched_on: null, watched: true, note: "" },
        { name: "Crouching Tiger, Hidden Dragon", year: null, watched_on: null, watched: false, note: "" },
    ]);
});

test("cleanDate only accepts real days that aren't in the future", () => {
    assert.strictEqual(cleanDate("2021-07-04"), "2021-07-04");
    assert.strictEqual(cleanDate("2021-13-01"), null);
    assert.strictEqual(cleanDate("07/04/2021"), null);
    assert.strictEqual(cleanDate("2999-01-01"), null);
    assert.strictEqual(cleanDate(45000), null);
});

test("matchFilms matches titles by year, accents and a year either side, keeping the sheet's order", async () => {
    const films = cleanFilms([
        { name: "Heat", year: 1995 },
        { name: "Not A Real Film Xyz", year: 2010 },
        { name: "Amelie", year: 2001 },
        { name: "Crouching Tiger, Hidden Dragon", year: 2001 },
    ]);
    const matched = await matchFilms(films);
    assert.deepStrictEqual(matched.map((movie) => movie?.id ?? null), [949, null, 194, 146]);
    assert.strictEqual(describeFilm(films[1]), "Not A Real Film Xyz (2010)");
});
