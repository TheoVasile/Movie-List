//
//  List.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct ListView: View {
    @EnvironmentObject var network: NetworkService
    //@EnvironmentObject var db: DatabaseService
    //@ObservedObject var viewModel: ListViewModel
    var movieList: CDMovieList
    @FetchRequest(fetchRequest: CDMovie.fetch(), animation: .bouncy) var movies: FetchedResults<CDMovie>
    @State var showPopup: Bool = false
    @State var movieName: String = ""
    @State var movieYear: String = ""
    @State var searchText: String = ""
    
    @State var recommendedMovie = ""
    
    @State var otherSearchResults: [String] = []
    @Environment(\.managedObjectContext) var context
    
    
    init(movieList: CDMovieList){
        self.movieList = movieList
        let request = CDMovie.fetch()
        request.predicate = NSPredicate(format: "list == %@", movieList as CVarArg)
        self._movies = FetchRequest(fetchRequest: request)
    }
    
    var body: some View{
        ZStack{
            NavigationView{
                VStack{
                    List {
                        dailyMovie
                        ForEach(movies){movie in
                            MovieRow(movie: movie)
                        }
                        //.onDelete { indexSet in
                        //    movieList?.movies.remove(movieList?.movies[indexSet.first ?? 0])
                        //}
                    }
                }
                .searchable(text: $searchText) {
                    searchResultsList
                }
                .navigationTitle(movieList.name!)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){ optionsMenu }
                }
            }
            .popupNavigationView(horizontalPadding: 20, show: $showPopup){ popup }
        }
        .onAppear {
                    //viewModel.setup(db: db, network: network)
                }
    }
}

private extension ListView {
    var dailyMovie: some View {
        Group {
            if movieList.movies.count > 0 {
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
            NavigationLink("Compare", destination: CompareMovieView(listName: movieList.name!))
            Button("Recommend Movie"){
                //recommendedMovie = viewModel.recommendMovie()
                print("RECOMMENDATION: \(recommendedMovie)")
            }
        }
    }
    
    var searchResultsList: some View {
        //ForEach(viewModel.searchResults(searchText: searchText), id: \.self) { result in
        //    Text("\(result)").searchCompletion(result)
        //}
        Text("PlaceHolder")
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
                        Button("Search"){ search(searchText: searchText) }
                    }
                }
            
        }
    }
    
    func search(searchText: String) {
        
    }
    
    func movieCard(movie: Movie) -> some View {
        HStack{
            Text("\(String(movie.rank ?? -1)).")
            Text(movie.title)
            Text("(\(String(movie.year ?? -1)))")
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


struct List_Previews: PreviewProvider{
    static var previews: some View {
        ListView(movieList: CDMovieList.example)
            .environmentObject(NetworkService())
    }
}
