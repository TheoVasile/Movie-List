//
//  List.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct ListView: View {
    @EnvironmentObject var network: Network
    @EnvironmentObject var db: DataAccess
    @ObservedObject var viewModel: ListViewModel
    @State var showPopup: Bool = false
    @State var movieName: String = ""
    @State var movieYear: String = ""
    @State var searchText: String = ""
    
    @State var recommendedMovie = ""
    
    @State var otherSearchResults: [String] = []
    
    init(listName: String){
        _viewModel = ObservedObject(wrappedValue: ListViewModel(listName: listName))
    }
    
    var body: some View{
        ZStack{
            NavigationView{
                VStack{
                    movieList(movieArray: viewModel.movieArray)
                }
                .searchable(text: $searchText) {
                    searchResultsList
                }
                .navigationTitle(viewModel.listName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){ optionsMenu }
                }
            }
            .popupNavigationView(horizontalPadding: 20, show: $showPopup){ popup }
        }
        .onAppear {
                    viewModel.setup(db: db, network: network)
                }
    }
}

private extension ListView {
    var dailyMovie: some View {
        Group {
            if viewModel.hasItems() {
                Section("Movie of the Day: \(recommendedMovie)"){
                    Image("Babylon")
                        .resizable()
                        .frame(width: 200, height: 295)
                        .cornerRadius(25)
                }
            } else {
                Text("No Movies Added")
            }
        }
    }
    
    // Options to manipulate the list
    var optionsMenu: some View {
        Menu("Options") {
            Button("Add Movie"){ showPopup.toggle() }
            NavigationLink("Compare", destination: CompareMovieView(listName: viewModel.listName))
                .environmentObject(db)
            Button("Recommend Movie"){
                recommendedMovie = viewModel.recommendMovie()
                print("RECOMMENDATION: \(recommendedMovie)")
            }
        }
    }
    
    var searchResultsList: some View {
        ForEach(viewModel.searchResults(searchText: searchText), id: \.self) { result in
            Text("\(result)").searchCompletion(result)
        }
    }
    
    var popup: some View {
        VStack{
            VStack{ List{ Text("") } }
                .searchable(text: $searchText) {
                    ForEach(network.movies) { movie in
                        Text("\(movie.title)").searchCompletion(movie.title)
                    }
                }
                .navigationTitle("Add New Movie")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close"){ withAnimation{ showPopup.toggle() } }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Search"){ viewModel.search(searchText: searchText) }
                    }
                }
            
        }
    }
    
    func movieCard(movie: Movie) -> some View {
        HStack{
            Text("\(String(movie.rank)).")
            Text(movie.name)
            Text("(\(String(movie.year)))")
        }
    }
    
    func movieList(movieArray: [Movie]) -> some View {
        List {
            dailyMovie
            ForEach(movieArray){movie in
                movieCard(movie: movie)
            }
            .onMove(perform: viewModel.move)
            .onDelete { indexSet in
                viewModel.deleteMovie(name: movieArray[indexSet.first ?? 0].name, year: nil)
            }
        }
    }
    
    func header(recommendedMovie: String) -> some View {
        VStack{
            Text("Movie of the Day: \(recommendedMovie)")
            Image("Babylon")
                .resizable()
                .frame(width: 200, height: 295)
                .cornerRadius(25)
        }
    }
}

class ListViewModel: ObservableObject {
    var db: DataAccess?=nil
    var network: Network?=nil
    var listName: String
    var movieArray: [Movie]=[]
    
    init(listName: String) {
        self.listName = listName
    }
    
    func setup(db: DataAccess, network: Network) {
        self.db = db
        self.network = network
    }
    
    func getMovieNames(movieArray: Array<Movie>) -> [String]{
        var movieNames: [String] = []
        for movie in movieArray {
            movieNames.append(movie.name)
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
        
        self.setRank(name: movie1.name, year: movie1.year, rank: Int64(toIndex + 1))
        
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
    
    func recommendMovie() -> String{
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
        
        return selectedMovie?.name ?? ""
    }
}

struct List_Previews: PreviewProvider{
    static var previews: some View{
        ListView(listName: "Test List")
            .environmentObject(DataAccess())
            .environmentObject(Network())
    }
}
