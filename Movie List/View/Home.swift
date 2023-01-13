//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @State var showPopup: Bool = false
    @State var showLists: Bool = false
    @State var listName: String = ""
    
    let userDefaults = UserDefaults.standard
    let listsKey = "movie_lists"
    
    
    var body: some View{
        let db = DataAccess()
        let array = db.getLists() ?? []
        if array.count == 0{
            Text("No Lists")
        } else{
            NavigationView{
                VStack{
                    Text("Movie Lists")
                    ForEach(array, id: \.self) {list in
                        NavigationLink(list, destination: ListView())
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
