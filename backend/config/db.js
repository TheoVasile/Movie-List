const { Pool, types } = require("pg");
require("dotenv").config();

// TIMESTAMP columns have no timezone and the database runs in UTC, but pg would read them as this
// machine's local time, shifting every date by the local UTC offset. Read them as UTC instead
const TIMESTAMP_WITHOUT_TIME_ZONE = 1114;
types.setTypeParser(TIMESTAMP_WITHOUT_TIME_ZONE, (value) => new Date(value.replace(" ", "T") + "Z"));

function getPool() {
    let pool;
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

        console.log("New database connection pool created");
    }
    return pool;
}

const pool = getPool();

module.exports = pool;