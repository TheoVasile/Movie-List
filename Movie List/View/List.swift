//
//  List.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct ListView: View {
    
    @State var showPopup: Bool = false
    @State var listName: String
    @State var movieName: String = ""
    @State var movieYear: String = ""
    
    @State var movieArray: Array<Movie>
    
    init(listName: String){
        self.listName = listName
        
        movieArray = db.getMovieList(list: listName) ?? []
    }
    
    var body: some View{
        let _ = print(movieArray)
        ZStack{
            NavigationView{
                VStack{
                    if movieArray.count == 0{
                        Text("No Movies Added Yet")
                    }
                    List {
                        
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
                .navigationTitle(listName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){
                        Menu("Options") {
                            Button("Add Movie"){}
                            Button("Compare Movies"){}
                            Button("Recommend Movie"){}
                                }
                    }
                    /**
                    ToolbarItem(placement: .navigationBarTrailing){
                        Button{
                            withAnimation{showPopup.toggle()}
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing){
                        NavigationLink("Compare", destination: CompareMovieView(listName: listName))
                    }
                     */
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
