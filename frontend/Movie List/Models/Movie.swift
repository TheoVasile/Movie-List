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

    /// TV shows have negative ids, since TMDb's film and TV ids overlap (see backend/services/tmdbMedia.js)
    var isTV: Bool { id < 0 }
}
