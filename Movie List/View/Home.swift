//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

struct Home: View {
    
    @State var showPopup: Bool = false
    @State var listName: String = ""
    
    var body: some View{
        NavigationView {
            VStack{
                Text("Movies List")
                Button("New List"){
                    withAnimation{
                        showPopup.toggle()
                    }
                }
                .buttonStyle(.bordered)
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
                Button("View List"){}
                    .buttonStyle(.bordered)
                Button("Add Movie"){}
                    .buttonStyle(.bordered)
                Button("Compare Movies"){}
                    .buttonStyle(.bordered)
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
