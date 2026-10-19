// Connect to PostgreSQL
const pool = require("../config/db");

// Define table creation queries
const createTables = async () => {
    //const client = await pool.connect( (err, connection) => {
    //    if (err) throw err;
    //    console.log('Database is connected successfully !');
    //    connection.release();
    //  }); 
    console.log("Connected to database");
    try {
        console.log("Creating database tables");
        await pool.query(`
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                firebase_uid VARCHAR(255) UNIQUE NOT NULL, 
                username VARCHAR(50) UNIQUE NOT NULL,
                email VARCHAR(255) UNIQUE NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS movies (
                id SERIAL PRIMARY KEY,
                tmdb_id VARCHAR(20) UNIQUE,
                title VARCHAR(255) NOT NULL,
                release_date VARCHAR(20),
                overview TEXT,
                poster_path VARCHAR(255),
                original_language VARCHAR(10),
                popularity DOUBLE PRECISION,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS lists (
                id SERIAL PRIMARY KEY,
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                name VARCHAR(100) NOT NULL,
                overview TEXT,
                is_ranked BOOLEAN DEFAULT FALSE,
                creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                date_modified TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS list_movies (
                id SERIAL PRIMARY KEY,
                list_id INT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                rank INT,
                UNIQUE (list_id, movie_id)
            );

            -- Watched is per user, not per list: a film watched once shows as watched in every list
            CREATE TABLE IF NOT EXISTS watched_movies (
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                watched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, movie_id)
            );

            -- A user's private note on a film, shared across their lists like watched
            CREATE TABLE IF NOT EXISTS movie_notes (
                user_id VARCHAR(255) NOT NULL REFERENCES users(firebase_uid) ON DELETE CASCADE,
                movie_id INT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
                note TEXT NOT NULL,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, movie_id)
            );
        `);

        console.log("Tables created successfully");
    } catch (error) {
        console.error("Error creating tables:", error);
    } finally {
        //await client.release();
    }
};

// Run the script
//createTables();

module.exports = createTables;