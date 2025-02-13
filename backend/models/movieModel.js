const pool = require("../config/db");

async function createMovie(tmdb_id, title, release_date, overview, poster_path, original_language, popularity) {
    const result = await pool.query(
        "INSERT INTO movies (tmdb_id, title, release_date, overview, poster_path, original_language, popularity) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (tmdb_id) DO NOTHING RETURNING *;",
        [tmdb_id, title, release_date, overview, poster_path, original_language, popularity]
    );
    // ✅ If the movie was inserted, return the newly created row
    if (result.rows.length > 0) {
        return result.rows[0];
    }

    // ✅ If no row was inserted, fetch the existing row
    const existingMovie = await pool.query(
        `SELECT * FROM movies WHERE tmdb_id = $1;`,
        [tmdb_id]
    );

    return existingMovie.rows[0];
}

async function removeMovieFromList(list_id, movie_id) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN"); // Start transaction

        // ✅ Delete the movie and return the deleted row
        const result = await client.query(
            `DELETE FROM list_movies WHERE list_id = $1 AND movie_id = $2 RETURNING *`,
            [list_id, movie_id]
        );

        if (result.rowCount === 0) {
            await client.query("COMMIT"); // Commit even if nothing is deleted
            return { message: "No matching movie found, but operation successful." };
        }

        // ✅ Reorder rankings after deletion
        await client.query(
            `UPDATE list_movies
             SET rank = new_rank
             FROM (
                 SELECT movie_id, ROW_NUMBER() OVER (ORDER BY rank) AS new_rank
                 FROM list_movies
                 WHERE list_id = $1
             ) AS ranked
             WHERE list_movies.list_id = $1 AND list_movies.movie_id = ranked.movie_id`,
            [list_id]
        );

        await client.query("COMMIT"); // Commit transaction
        return result.rows[0]; // Return the deleted movie
    } catch (error) {
        await client.query("ROLLBACK"); // Rollback on error
        console.error("Error removing movie from list:", error);
        throw error;
    } finally {
        client.release(); // Release the client
    }
}

async function addMovieToList(list_id, movie_id, rank) {
    try {
        const result = await pool.query(
            "INSERT INTO list_movies (list_id, movie_id, rank) VALUES ($1, $2, $3)",
            [list_id, movie_id, rank]
        );
        return result.rows[0];
    } catch (error) {
        console.error("Error adding movie to list:", error);
        throw error;
    }
}

async function updateMovieRank(list_id, movie_id, new_rank) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN"); // Start transaction

        // Get the current rank of the movie
        const { rows } = await client.query(
            "SELECT rank FROM list_movies WHERE list_id = $1 AND movie_id = $2",
            [list_id, movie_id]
        );

        if (rows.length === 0) {
            throw new Error("Movie not found in the list");
        }

        const old_rank = rows[0].rank;
        if (old_rank === new_rank) {
            await client.query("COMMIT"); // No updates needed, but commit transaction
            return rows[0]; // ✅ Return the existing row as-is
        }
        // Shift affected movies up or down
        await client.query(
            `UPDATE list_movies
             SET rank = CASE
                 WHEN CAST($1 AS INTEGER) < CAST($2 AS INTEGER) THEN rank - 1
                 WHEN CAST($1 AS INTEGER) > CAST($2 AS INTEGER) THEN rank + 1
                 ELSE rank
             END
             WHERE list_id = CAST($3 AS INTEGER)
             AND rank BETWEEN LEAST(CAST($1 AS INTEGER), CAST($2 AS INTEGER))
                         AND GREATEST(CAST($1 AS INTEGER), CAST($2 AS INTEGER))
             AND movie_id != CAST($4 AS INTEGER)`,
            [old_rank, new_rank, list_id, movie_id]
        );

        // Update the movie's rank
        const result = await client.query(
            "UPDATE list_movies SET rank = $1 WHERE list_id = $2 AND movie_id = $3 RETURNING *",
            [new_rank, list_id, movie_id]
        );
        await client.query("COMMIT"); // Commit transaction
        return result.rows[0];

    } catch (error) {
        await client.query("ROLLBACK"); // Rollback in case of error
        console.error("Error updating movie rank:", error);
        throw error;
    } finally {
        client.release(); // Release DB connection
    }
}


async function getMovieByTmdbId(tmdb_id) {
    const result = await pool.query(
        "SELECT * FROM movies WHERE tmdb_id = $1",
        [tmdb_id]
    );
    return result.rows[0];
}

module.exports = { createMovie, addMovieToList, getMovieByTmdbId, removeMovieFromList, updateMovieRank };