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
    
    init(listName: String){
        self.listName = listName
    }
    
    var body: some View{
        let movieArray = db.getMovieList(list: listName) ?? []
        let _ = print(movieArray)
        ZStack{
            NavigationView{
                VStack{
                    if movieArray.count == 0{
                        Text("No Movies Added Yet")
                    }
                    List {
                        
                        ForEach(movieArray, id: \.self){movieName in
                            Text(movieName)
                        }
                        .onDelete { indexSet in
                            if db.deleteMovie(list: listName, name: movieArray[indexSet.first ?? 0], year: nil) < 0 {
                                print("Failed to delete movie")
                            }
                        }
                        
                    }
                }
                .navigationTitle(listName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
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
                }
            }
            .popupNavigationView(horizontalPadding: 40, show: $showPopup){
                VStack{
                    TextField("Movie Name", text: $movieName)
                    TextField("Movie Year", text: $movieYear)
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
                                        if db.addMovie(list: listName, name: movieName, year: Int64(movieYear) ?? 0, rank: 0) < 0{
                                            print("failed to add Movie")
                                        }
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
}

struct List_Previews: PreviewProvider{
    static var previews: some View{
        ListView(listName: "Test List")
    }
}
