//
//  MovieRow.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-05-04.
//

import Foundation
import SwiftUI

struct MovieRow: View {
    @ObservedObject var movie: CDMovie
    
    var body: some View {
        HStack{
            Text("\(String(movie.rank)).")
            Text(movie.title ?? "No title")
            Text(yearString(from: movie.release_date!))
        }
    }
    
    func yearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }
}

#Preview {
    MovieRow(movie: CDMovie.example)
}
