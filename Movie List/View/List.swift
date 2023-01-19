//
//  List.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

func recommendMovie(list: String) -> String{
    /**
     Return the name of a movie in the given list. More likely to return highly rated movies.
     If there are no movies, return an empty string
     */
    let numMovies = Double(db.getListLength(list: list))
    if numMovies < 1 {
        return ""
    }
    let selectedRank = round((1 - Double.random(in: 0 ..< numMovies) / numMovies).squareRoot() * (numMovies - 1) + 1)
    print("SELECTED RANK: \(selectedRank)")
    let selectedMovie = db.getMovieFromRank(list: list, rank: Int64(selectedRank))
    
    return selectedMovie!.name
}

@ViewBuilder
func header(recommendedMovie: String) -> some View {
    VStack{
        Text("Movie of the Day: \(recommendedMovie)")
        Image("Babylon")
            .resizable()
            .frame(width: 200, height: 295)
            .cornerRadius(25)
    }
}

func getMovieNames(movieArray: Array<Movie>) -> [String]{
    var movieNames: [String] = []
    for movie in movieArray {
        movieNames.append(movie.name)
    }
    return movieNames
}

struct ListView: View {
    
    @State var showPopup: Bool = false
    @State var listName: String
    @State var movieName: String = ""
    @State var movieYear: String = ""
    @State var searchText: String = ""
    
    @State var movieArray: Array<Movie>
    @State var recommendedMovie: String
    
    init(listName: String){
        self.listName = listName
        
        movieArray = db.getMovieList(list: listName) ?? []
        
        recommendedMovie = recommendMovie(list: listName)
    }
    
    var searchResults: [String] {
        if searchText.isEmpty {
            return []
        } else {
            return getMovieNames(movieArray: movieArray).filter{$0.contains(searchText)}
        }
    }
    
    var body: some View{
        ZStack{
            NavigationView{
                VStack{
                    List {
                        Section("Movie of the Day: \(recommendedMovie)"){
                            Image("Babylon")
                                .resizable()
                                .frame(width: 200, height: 295)
                                .cornerRadius(25)
                        }
                        ForEach(movieArray){movie in
                            HStack{
                                Text("\(String(movie.rank)).")
                                Text(movie.name)
                                Text("(\(String(movie.year)))")
                            }
                        }
                        .onMove(perform: move)
                        .onDelete { indexSet in
                            if db.deleteMovie(list: listName, name: movieArray[indexSet.first ?? 0].name, year: nil) < 0 {
                                print("Failed to delete movie")
                            }
                            updateMovieList()
                        }
                    }
                }
                .searchable(text: $searchText) {
                    ForEach(searchResults, id: \.self) { result in
                        Text("\(result)").searchCompletion(result)
                    }
                }
                .navigationTitle(listName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){
                        Menu("Options") {
                            Button("Add Movie"){showPopup.toggle()}
                            NavigationLink("Compare", destination: CompareMovieView(listName: listName))
                            Button("Recommend Movie"){
                                recommendedMovie = recommendMovie(list: listName)
                                print("RECOMMENDATION: \(recommendedMovie)")
                            }
                        }
                    }
                }
            }
            .popupNavigationView(horizontalPadding: 20, show: $showPopup){
                VStack{
                    TextField("Movie Name", text: $movieName)
                        .padding()
                    TextField("Movie Year", text: $movieYear)
                        .padding(.horizontal)
                        .navigationTitle("Add New Movie")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar{
                            ToolbarItem(placement: .navigationBarLeading){
                                Button("Close"){
                                    withAnimation{
                                        showPopup.toggle()
                                    }
                                }
                            }
                            ToolbarItem(placement: .bottomBar){
                                Button("Add"){
                                    if movieName.count > 0 && movieYear.count > 0{
                                        if db.addMovie(list: listName, name: movieName, year: Int64(movieYear) ?? 0, rank: Int64(movieArray.count + 1)) < 0{
                                            print("failed to add Movie")
                                        }
                                        updateMovieList()
                                        movieName = ""
                                        movieYear = ""
                                        withAnimation{showPopup.toggle()}
                                    }
                                }
                            }
                        }
                }
            }
        }
    }
    
    func updateMovieList(){
        movieArray = db.getMovieList(list: listName) ?? []
    }
    
    func move(from source: IndexSet, to destination: Int) {
        
        let fromIndex: Int = source.first ?? 0
        var toIndex: Int = destination
        if fromIndex < toIndex {
            toIndex -= 1
        }
        print("SOURCE: \(fromIndex)")
        print("DESTINATION: \(toIndex)")
        
        let movie1 = movieArray[fromIndex]
        
        if db.setRank(list: listName, name: movie1.name, year: movie1.year, rank: Int64(toIndex + 1)) < 0 {
            print("Unable to set rank on movie 1")
        }
        
        updateMovieList()
    }
}

struct List_Previews: PreviewProvider{
    static var previews: some View{
        ListView(listName: "Test List")
    }
}
