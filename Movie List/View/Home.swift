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
    
    var body: some View{
        NavigationView {
            Text("Movies List")
            Button("New List"){
                withAnimation{
                    showPopup.toggle()
                }
            }
            .buttonStyle(.bordered)
            .popupNavigationView(horizontalPadding: 40, show: $showPopup){
                Text("Jeff")
                    .navigationTitle("Popup")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar{
                        ToolbarItem(placement: .navigationBarTrailing){
                            Button{
                                
                            } label: {
                                Image(systemName: "plus")
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
        .padding()
    }
}

struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
    }
}
