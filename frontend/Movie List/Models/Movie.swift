//
//  Movie.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-27.
//

import Foundation

// Codable so Discover can save the cards still to swipe between launches
struct Movie: Identifiable, Codable {
    var id: Int64
    var title: String
    var release_date: String
    var overview: String
    var poster_path: String?
    var original_language: String
    var popularity: Double
    // Only sent by the discover endpoint
    var vote_average: Double?
    var genre_ids: [Int]?
    // Why this film was picked: from the AI, or for Classic movie nights a line like "On both your watchlists"
    var reason: String?
    // True when the AI (Claude) picked it; only then does the reason get the AI's sparkles
    var ai: Bool? = nil
    // Only sent by Discover's ranked feed: how well the server thinks it fits, why it was picked ("seed", "taste",
    // "explore", "friend" or "trending") and, for "friend", who recommended it. Older servers leave them out
    var score: Double? = nil
    var source: String? = nil
    var recommended_by: Recommender? = nil

    struct Recommender: Codable, Equatable {
        let handle: String
        let display_name: String?
    }

    /// TV shows have negative ids, since TMDb's film and TV ids overlap (see backend/services/tmdbMedia.js)
    var isTV: Bool { id < 0 }
}

// Decoded by hand so the fields Discover's ranked feed adds never stop a film loading: missing or unexpected ones
// are just left out
extension Movie {
    private enum CodingKeys: String, CodingKey {
        case id, title, release_date, overview, poster_path, original_language, popularity, vote_average, genre_ids
        case reason, ai, score, source, recommended_by
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        release_date = try container.decode(String.self, forKey: .release_date)
        overview = try container.decode(String.self, forKey: .overview)
        poster_path = try container.decodeIfPresent(String.self, forKey: .poster_path)
        original_language = try container.decode(String.self, forKey: .original_language)
        popularity = try container.decode(Double.self, forKey: .popularity)
        vote_average = try container.decodeIfPresent(Double.self, forKey: .vote_average)
        genre_ids = try container.decodeIfPresent([Int].self, forKey: .genre_ids)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        ai = try container.decodeIfPresent(Bool.self, forKey: .ai)
        score = try? container.decodeIfPresent(Double.self, forKey: .score)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        recommended_by = try? container.decodeIfPresent(Recommender.self, forKey: .recommended_by)
    }
}
