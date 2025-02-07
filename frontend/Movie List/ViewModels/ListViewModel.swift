//
//  ListViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation

class ListViewModel: ObservableObject {
    /*
    var db: DatabaseService?=nil
    var network: NetworkService?=nil
    var listName: String
    @Published var movieArray: [Movie]=[]
    
    init(listName: String) {
        self.listName = listName
        network?.$movies.assign(to: &$movieArray)
    }
    
    func setup(db: DatabaseService, network: NetworkService) {
        self.db = db
        self.network = network
    }
    
    func getMovieNames(movieArray: Array<Movie>) -> [String]{
        var movieNames: [String] = []
        for movie in movieArray {
            movieNames.append(movie.title)
        }
        return movieNames
    }
    
    func search(searchText: String) {
        if searchText.count > 0 {
            Task {
                await network?.searchMovies(name: searchText)
            }
        }
    }
    
    func searchResults(searchText: String) -> [String] {
        if searchText.isEmpty {
            return []
        } else {
            return getMovieNames(movieArray: movieArray).filter{$0.contains(searchText)}
        }
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
        
        self.setRank(name: movie1.title, year: movie1.year ?? 0, rank: Int64(toIndex + 1))
        
        self.updateMovieList()
    }
    
    func deleteMovie(name: String, year: Int64?) {
        if (db?.deleteMovie(list: listName, name: name, year: year) ?? -1) < 0 {
            print("Failed to delete movie")
        }
        self.updateMovieList()
    }
    
    func hasItems() -> Bool {
        return (db?.getListLength(list: listName) ?? -1) > 0
    }
    
    func setRank(name: String, year: Int64, rank: Int64){
        if (db?.setRank(list: listName, name: name, year: year, rank: rank) ?? -1) < 0 {
            print("Unable to set rank on movie 1")
        }
    }
    
    func updateMovieList(){
        movieArray = db?.getMovieList(list: listName) ?? []
    }
    
    func recommendMovie() -> String {
        /**
         Return the name of a movie in the given list. More likely to return highly rated movies.
         If there are no movies, return an empty string
         */
        let numMovies = Double(db?.getListLength(list: listName) ?? Int(0.0))
        if numMovies < 1 {
            return ""
        }
        let selectedRank = round((1 - Double.random(in: 0 ..< numMovies) / numMovies).squareRoot() * (numMovies - 1) + 1)
        print("SELECTED RANK: \(selectedRank)")
        let selectedMovie = db?.getMovieFromRank(list: listName, rank: Int64(selectedRank)) ?? nil
        
        return selectedMovie?.title ?? ""
    }
     */
}
