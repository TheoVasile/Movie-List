// Where Marquee's public pages and universal links live. The one place the backend's public address is set:
// PUBLIC_BASE_URL (no trailing slash), e.g. https://onmarquee.app once that domain is bought and pointed here.
// The app has its own copy in frontend/Movie List/Services/ShareLinks.swift, plus the applinks: entry in its
// entitlements; switching domains means changing those and this env var, nothing else
const DEFAULT_BASE_URL = "https://movie-list-backend-dgct.onrender.com";

function publicBaseURL() {
    return (process.env.PUBLIC_BASE_URL || DEFAULT_BASE_URL).replace(/\/+$/, "");
}

/// The address without its scheme, for the footer of share cards and pages, e.g. "onmarquee.app"
function shortDomain() {
    return publicBaseURL().replace(/^https?:\/\//, "");
}

/// The app's id on the App Store (digits), for the Smart App Banner and "Get the app". Not set until the app is
/// listed. TODO: set APP_STORE_ID on Render once the App Store listing exists
function appStoreID() {
    const id = process.env.APP_STORE_ID;
    return id && /^\d+$/.test(id) ? id : null;
}

/// Where "Get the app" goes: the App Store listing, or the App Store's search until there is one
function appStoreURL() {
    const id = appStoreID();
    return id ? `https://apps.apple.com/app/id${id}` : "https://apps.apple.com/search?term=Marquee%20films";
}

// Team ID + bundle id, which iOS checks against the app's Associated Domains entitlement
const APP_ID = "MQB3MHVNQQ.Theodor-Vasile.Movie-List";
// The paths the app opens itself instead of the browser
const LINK_PATHS = ["/l/*", "/u/*", "/f/*", "/i/*", "/join/*"];

/// The apple-app-site-association file: both the current format (appIDs + components) and the older one
/// (appID + paths) that iOS 12 and earlier read
function appSiteAssociation() {
    return {
        applinks: {
            apps: [],
            details: [
                {
                    appIDs: [APP_ID],
                    components: LINK_PATHS.map((path) => ({ "/": path })),
                    appID: APP_ID,
                    paths: LINK_PATHS,
                },
            ],
        },
    };
}

/// Links to each public page
const links = {
    list: (publicId) => `${publicBaseURL()}/l/${publicId}`,
    profile: (handle) => `${publicBaseURL()}/u/${encodeURIComponent(handle)}`,
    film: (tmdbId) => `${publicBaseURL()}/f/${tmdbId}`,
    personalInvite: (handle) => `${publicBaseURL()}/i/${encodeURIComponent(handle)}`,
    groupInvite: (token) => `${publicBaseURL()}/join/group/${token}`,
};

module.exports = { DEFAULT_BASE_URL, APP_ID, LINK_PATHS, publicBaseURL, shortDomain, appStoreID, appStoreURL, appSiteAssociation, links };
