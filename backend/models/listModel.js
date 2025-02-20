const pool = require("../config/db");

async function createList(user_id, name, overview, is_ranked) {
    const result = await pool.query(
        "INSERT INTO lists (user_id, name, overview, is_ranked) VALUES ($1, $2, $3, $4) RETURNING *",
        [user_id, name, overview, is_ranked]
    );
    return result.rows[0];
}

async function fetchLists(user_id) {
    const result = await pool.query(
        "SELECT * FROM lists WHERE user_id = $1",
        [user_id]
    );
    const lists = result.rows;

    for (const list of lists) {
        list.movies = [];
        const movies = await pool.query(
            "SELECT * FROM list_movies WHERE list_id = $1",
            [list.id]
        );
        for (const movie of movies.rows) {
            const movieDetails = await pool.query(
                "SELECT * FROM movies WHERE id = $1",
                [movie.movie_id]
            );
            const movieDetailsResult = movieDetails.rows[0];
            movieDetailsResult.rank = movie.rank;
            list.movies.push(movieDetailsResult);
        }
    }

    return lists;
}

async function deleteList(list_id) {
    try {
        await pool.query("BEGIN");
        await pool.query("DELETE FROM list_movies WHERE list_id = $1", [list_id]);
        const result = await pool.query(
            "DELETE FROM lists WHERE id = $1",
            [list_id]
        );
        await pool.query("COMMIT");
        return result.rows[0];
    } catch (error) {
        await pool.query("ROLLBACK");
        throw error;
    }
}

module.exports = { createList, deleteList, fetchLists };