//
//  CompareMovieView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct CompareMovieView: View {
    
    @State var movieList: Array<String>
    
    @State var movie1: String = "Movie 1"
    @State var movie2: String = "Movie 2"
    
    init(listName: String){
        self.movieList = db.getMovieList(list: listName) ?? []
        selectMovies()
    }
    
    func selectMovies(){
        self.movie1 = movieList.randomElement() ?? "Movie 1"
        self.movie2 = movieList.randomElement() ?? "Movie 2"
    }
    
    var body: some View{
        NavigationView{
            HStack{
                Button(movie1){
                    selectMovies()
                }
                Button(movie2){
                    selectMovies()
                }
            }
        }
        .navigationTitle("Compare Movies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CompareMovieView_Previews: PreviewProvider{
    static var previews: some View{
        CompareMovieView(listName: "Test List")
    }
}

