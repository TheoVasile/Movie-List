//
//  CompareMovieView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct CompareMovieView: View {
    var body : some View {
        Text("Placeholder")
    }
    /*
    @EnvironmentObject var db: DatabaseService
    @State var movieList: Array<Movie>
    var listName: String
    
    @State var movie1: String = "Movie 1"
    @State var movie2: String = "Movie 2"
    
    init(listName: String){
        self.listName = listName
        _movieList = State(initialValue: [])
    }
    
    func selectMovies(){
        self.movie1 = movieList.randomElement()?.title ?? "Movie 1"
        self.movie2 = movieList.randomElement()?.title ?? "Movie 2"
    }
    
    var body: some View{
        NavigationView{
            VStack{
                Text("Select Which Movie You Think is Better")
                HStack{
                    Button{
                        selectMovies()
                    } label: {
                        ZStack{
                            RoundedRectangle(cornerRadius: 25)
                                .fill(.white)
                                .frame(width:150, height:150)
                                .shadow(radius: 5)
                            Text(movie1)
                        }
                    }
                    Button{
                        selectMovies()
                    } label: {
                        ZStack{
                            RoundedRectangle(cornerRadius: 25)
                                .fill(.white)
                                .frame(width:150, height:150)
                                .shadow(radius: 5)
                            Text(movie2)
                        }
                    }
                }
            }
        }
        .onAppear{
            movieList = db.getMovieList(list: listName) ?? []
            selectMovies()
        }
        .navigationTitle("Compare Movies")
        .navigationBarTitleDisplayMode(.inline)
    }
     */
}

struct CompareMovieView_Previews: PreviewProvider{
    static var previews: some View{
        CompareMovieView()
            .environmentObject(NetworkService())
    }
}

