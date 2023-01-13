//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @State var showPopup: Bool = false
    @State var listName: String = ""
    
    let userDefaults = UserDefaults.standard
    let listsKey = "movie_lists"
    
    
    var body: some View{
        ZStack{
            NavigationView {
                VStack{
                    Text("Movies List")
                    Button("New List"){
                        withAnimation{
                            showPopup.toggle()
                        }
                    }
                    NavigationLink("View List", destination: List())
                    NavigationLink("Add Movie", destination: AddMovieView())
                    NavigationLink("Compare Movies", destination: CompareMovieView())
                }
            }
            .popupNavigationView(horizontalPadding: 40, show: $showPopup){
                TextField(
                    "List Name",
                    text: $listName
                )
                .disableAutocorrection(true)
                .navigationTitle("Popup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){
                        Button{
                            
                        } label: {
                            Image(systemName: "plus")
                        }
                        .onTapGesture {
                            let defaults = UserDefaults.standard
                            defaults.set([], forKey: listName)
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading){
                        Button("Close"){
                            withAnimation{
                                showPopup.toggle()
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
    }
}
