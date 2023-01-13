//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @State var showPopup: Bool = false
    
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
                Text("ListName")
                    .disableAutocorrection(true)
                    .navigationTitle("Popup")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar{
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
    }
}

struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
    }
}
