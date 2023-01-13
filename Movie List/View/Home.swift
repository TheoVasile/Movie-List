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
    
    var body: some View{
        let db = DataAccess()
        let array = db.getLists() ?? []
        ZStack{
            NavigationView{
                VStack{
                    if array.count == 0{
                        Text("No Lists, Add One Now!")
                    }
                    ForEach(array, id: \.self) {list in
                        NavigationLink(list, destination: ListView())
                    }
                }
                .navigationTitle("Movie Lists")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){
                        Button{
                            withAnimation{showPopup.toggle()}
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .popupNavigationView(horizontalPadding: 40, show: $showPopup){
                TextField("ListName", text: $listName)
                    .disableAutocorrection(true)
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
                                if listName.count > 0{
                                    let db = DataAccess()
                                    if db.addMovie(list: listName, name: "", year: 0, rank: 0) < 0{
                                        print("failed to add list")
                                    }
                                    listName = ""
                                    withAnimation{showPopup.toggle()}
                                }
                            }
                        }
                    }
            }
        }
    }
}

struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
    }
}
