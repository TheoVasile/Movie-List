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
    @State var movieList: CDMovieList
    //@FetchRequest(fetchRequest: CDMovie.fetch(), animation: .bouncy) var movies: FetchedResults<CDMovie>
    @State var movies: [CDMovie] = []
    @State var showPopup: Bool = false
    @State var movieName: String = ""
    @State var movieYear: String = ""
    @State var searchText: String = ""
    @State var searchResults: [Movie] = []
    
    @State var recommendedMovie: CDMovie? = nil
    
    @State var otherSearchResults: [String] = []
    @Environment(\.managedObjectContext) var context
    
    /*
    init(movieList: CDMovieList){
        print("initializing")
        self.movieList = movieList
        //let request = CDMovie.fetch()
        //request.predicate = NSPredicate(format: "list == %@", movieList as CVarArg)
        //self._movies = FetchRequest(fetchRequest: request)
        self.movies = movieList.movies
    }*/
    
    private func deleteMovie(offsets: IndexSet) {
        for index in offsets {
            let poppedMovie: CDMovie = movies[index]
            movieList.movies.remove(poppedMovie)
        }
        movies = Array(movieList.movies).sorted(by: { $0.rank < $1.rank })
        for i in 0...(movies.count-1) {
            movies[i].rank = Int32(i+1)
        }
        movieList.movies = Set(movies)
        
    }
    
    var body: some View{
        ZStack{
            NavigationStack{
                VStack{
                    List {
                        if movies.count == 0 {
                            Text("No Movies Added")
                        } else if recommendedMovie != nil {
                            dailyMovie
                        }
                        ForEach(movies, id: \.id){movie in
                            MovieRow(movie: movie)
                        }
                        .onDelete { indexSet in
                            deleteMovie(offsets: indexSet)
                        }
                    }
                }
                .searchable(text: $searchText) {
                    searchResultsList
                }
                .navigationTitle(movieList.name ?? "no movie name")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){ optionsMenu }
                }
            }
            .overlay {
                if showPopup {
                    Color.primary
                        .opacity(0.15)
                        .ignoresSafeArea()
                    popup
                        .padding()
                }
            }
            //.popupNavigationView(horizontalPadding: 20, show: $showPopup){ popup }
        }
        .onAppear {
            movies = Array(movieList.movies).sorted(by: { $0.rank < $1.rank })
            //viewModel.setup(db: db, network: network)
        }
    }
}

private extension ListView {
    var dailyMovie: some View {
        Group {
            Section("Movie of the Day: \(String(describing: recommendedMovie?.title))"){
                AsyncImage(url: URL(string: "https://media.themoviedb.org/t/p/w600andh_900_bestv2/\(recommendedMovie?.poster_path ?? "/wjOHjWCUE0YzDiEzKv8AfqHj3ir.jpg")")) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 300, height: 200)
            }
        }
    }
    
    // Options to manipulate the list
    var optionsMenu: some View {
        Menu("Options") {
            Button("Add Movie"){ showPopup.toggle() }
            NavigationLink("Compare", destination: CompareMovieView(movieList: $movieList)
                .environmentObject(network))
            Button("Recommend Movie"){
                //recommendedMovie = viewModel.recommendMovie()
                print("RECOMMENDATION: \(recommendedMovie)")
            }
        }
    }
    
    var searchResultsList: some View {
        ForEach(Array(searchResults.enumerated()), id: \.offset) { index, result in
            Text("\(result.title)").searchCompletion(result.title)
        }
        //Text("PlaceHolder")
    }
    
    var popup: some View {
        VStack{
            HStack{
                Button(action: {
                    withAnimation { showPopup.toggle() }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium)) // Adjust size & weight
                }
                TextField("Search...", text: $searchText)
                    .padding(8)
                    .padding(.horizontal, 24)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .overlay(
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 8)
                        }
                    )
                    .submitLabel(.search) // 🔥 This makes the keyboard show a "Search" button
                    .onSubmit {
                        search(searchText: searchText) // Call your search function when the user taps "Search"
                    }
            }
            GeometryReader { geometry in
                VStack{
                    List {
                        ForEach(searchResults, id: \.id) { apiMovie in
                            Text("\(apiMovie.title), \(apiMovie.release_date)")
                                .onTapGesture {
                                    print("adding movie")
                                    createAndSaveMovie(from: apiMovie)
                                    showPopup.toggle()
                                }
                            }
                        }
                        .listStyle(.plain)
                        .cornerRadius(10)
                    }
                    .frame(maxHeight: min(CGFloat(searchResults.count * 50), geometry.size.height))
                }
                .navigationTitle("Add New Movie")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close"){ withAnimation{ showPopup.toggle() } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    
    private func createAndSaveMovie(from networkMovie: Movie) {
        print("COUNTS", movies.count)
        let newMovie = try! CDMovie(
            id: networkMovie.id,
            title: networkMovie.title,
            release_date: networkMovie.release_date,
            overview: networkMovie.overview,
            rank: Int32(movies.count + 1),
            poster_path: networkMovie.poster_path ?? "/zDifiMtI6MTIbGnjEMwzwOcoXZu.jpg",
            original_language: networkMovie.original_language,
            popularity: networkMovie.popularity,
            context: context)
        print("RANK", newMovie.rank)
        // newMovie.list!.adding(movieList)
        movieList.addToMovies_(newMovie)
        movies = Array(movieList.movies)
        // newMovie.addToList(movieList)

        do {
            print("saving context")
            try context.save()
            print(movies)
        } catch {
            print("Error saving context: \(error)")
        }
    }
    
    func search(searchText: String) {
        if searchText.count > 0 {
            Task {
                APIService.shared.searchMovies(name: searchText) { result in
                    switch result {
                    case .success(let movies):
                        self.searchResults = movies
                        print(searchResults)
                    case .failure(let error):
                        print(error.localizedDescription)
                    }
                }
            }
        }
    }
    
    func recommendMovie() -> CDMovie? {
        let numMovies = Double(movies.count)
        if numMovies < 1 {
            return nil
        }

        let selectedRank = round((1 - Double.random(in: 0..<numMovies)) / numMovies.squareRoot() * (numMovies - 1) + 1)
        print("SELECTED RANK: \(selectedRank)")

        let predicates = [NSPredicate(format: "list == %@", movieList.name ?? "no name" as CVarArg),
                          NSPredicate(format: "rank == %d", Int(selectedRank))]
        let request = CDMovie.fetch(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
        request.fetchLimit = 1  // We only want one movie

        do {
            let results = try context.fetch(request)
            return results.first  // Returns the first movie found, or nil if no movie matches
        } catch {
            print("Failed to fetch movie: \(error)")
            return nil
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
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
