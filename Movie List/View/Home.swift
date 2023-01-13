//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    var body: some View{
        let db = DataAccess()
        let array = db.getLists() ?? []
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
                        
                    } label: {
                        Image(systemName: "plus")
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
