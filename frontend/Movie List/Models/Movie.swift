//
//  Movie.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-27.
//

import Foundation

struct Movie: Identifiable, Decodable {
    var id: Int64
    var title: String
    var release_date: String
    var overview: String
    var poster_path: String?
    var original_language: String
    var popularity: Double
}
