//
//  List.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI
import CoreData

struct ListView: View {
    @EnvironmentObject var network: NetworkService
    @StateObject var viewModel: ListViewModel

    init(movieList: CDMovieList, context: NSManagedObjectContext) {
        _viewModel = StateObject(wrappedValue: ListViewModel(movieList: movieList, context: context))
    }

    var body: some View {
        ZStack {
            NavigationStack {
                VStack {
                    MovieListSection
                }
                .searchable(text: $viewModel.searchText) { SearchResultsList }
                .navigationTitle(viewModel.movieList.name ?? "No Movie Name")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarOptions }
            }
            //.overlay { if viewModel.showPopup { PopupOverlay } }
            if viewModel.showPopup {
                Color.primary
                    .opacity(0.15)
                    .ignoresSafeArea()
                popup
                    .padding()
            }
            else if viewModel.showCompareMovieView {
                if let selectedMovie = viewModel.selectedMovie {
                    CompareMovieView(movies: $viewModel.movies, movie: Binding.constant(selectedMovie)) { updatedMovie, rank in
                        viewModel.showCompareMovieView = false
                        viewModel.updateMovieRanking(updatedMovie: updatedMovie, newRank: rank)
                    }
                }
            }
            else if viewModel.showSetRank {
                if let selectedMovie = viewModel.selectedMovie {
                    SetRankView(movie: Binding.constant(selectedMovie)) {updatedMovie, rank in
                        viewModel.showSetRank = false
                        viewModel.updateMovieRanking(updatedMovie: updatedMovie, newRank: rank)
                    }
                }
            }
        }
    }
}

// MARK: - UI Components
private extension ListView {
    var MovieListSection: some View {
        List {
            if viewModel.movies.isEmpty {
                Text("No Movies Added")
            } else if viewModel.recommendedMovie != nil {
                DailyMovieView(movie: viewModel.recommendedMovie!)
            }
            ForEach(viewModel.movies, id: \.id) { movie in
                MovieRow(movie: movie, showCompareMovieView: $viewModel.showCompareMovieView, selectedMovie: $viewModel.selectedMovie, showSetRank: $viewModel.showSetRank)
            }
            .onDelete(perform: viewModel.deleteMovie)
        }
        .listStyle(.plain)
    }
    
    var SearchResultsList: some View {
        ForEach(viewModel.searchResults, id: \.id) { result in
            Text(result.title).searchCompletion(result.title)
        }
    }
    
    var ToolbarOptions: some View {
        Menu("Options") {
            Button("Add Movie") { viewModel.showPopup.toggle() }
            Button("Recommend Movie") { viewModel.recommendMovie() }
        }
    }
    
    var popup: some View {
            VStack{
                HStack{
                    Button(action: {
                        withAnimation { viewModel.showPopup.toggle() }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .medium)) // Adjust size & weight
                    }
                    TextField("Search...", text: $viewModel.searchText)
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
                            viewModel.searchMovies() // Call your search function when the user taps "Search"
                        }
                }
                GeometryReader { geometry in
                    VStack{
                        List {
                            ForEach(viewModel.searchResults, id: \.id) { apiMovie in
                                Text("\(apiMovie.title), \(apiMovie.release_date)")
                                    .onTapGesture {
                                        print("adding movie")
                                        viewModel.createAndSaveMovie(from: apiMovie)
                                        viewModel.showPopup.toggle()
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .cornerRadius(10)
                        }
                    .frame(maxHeight: min(CGFloat(viewModel.searchResults.count * 50), geometry.size.height))
                    }
                    .navigationTitle("Add New Movie")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close"){ withAnimation{ viewModel.showPopup.toggle() } }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
}

// MARK: - Daily Movie View
struct DailyMovieView: View {
    let movie: CDMovie
    
    var body: some View {
        Section("Movie of the Day: \(movie.title ?? "")") {
            AsyncImage(url: URL(string: "https://media.themoviedb.org/t/p/w600_and_h900_bestv2/\(movie.poster_path ?? "")")) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView()
            }
            .frame(width: 300, height: 200)
        }
    }
}


struct List_Previews: PreviewProvider {
    static var previews: some View {
        ListView(movieList: CDMovieList.example, context: PersistenceController.preview.container.viewContext)
            .environmentObject(NetworkService())
    }
}
