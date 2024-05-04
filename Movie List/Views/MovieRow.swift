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
            Text("\(String(movie.rank ?? -1)).")
            Text(movie.title ?? "No title")
            Text("(\(String(movie.release_date?.description ?? "Date not found")))")
        }
    }
}

#Preview {
    MovieRow(movie: CDMovie.example)
}
