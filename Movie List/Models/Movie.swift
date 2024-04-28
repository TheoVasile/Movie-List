//
//  Movie.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-27.
//

import Foundation

struct Movie: Identifiable, Decodable {
    var id: Int64?
    var poster_path: String?
    var title: String
    var year: Int64?
    var overview: String?
    var rank: Int64?
}
