const { Pool } = require("pg");
require("dotenv").config();

let pool;

function getPool() {
    if (!pool) {
        pool = new Pool({
            connectionString: process.env.DATABASE_URL,
            ssl: {
                rejectUnauthorized: false // Enable if your RDS requires SSL
            },
            max: 20, // Maximum number of clients in the pool
            idleTimeoutMillis: 30000, // How long a client is allowed to remain idle before being closed
            connectionTimeoutMillis: 2000, // How long to wait for a connection
        });

        // Add error handling
        pool.on('error', (err, client) => {
            console.error('Unexpected error on idle client', err);
        });

        console.log("✅ New database connection pool created");
    }
    return pool;
}

module.exports = getPool;