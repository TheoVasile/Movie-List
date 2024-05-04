//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @Environment(\.managedObjectContext) var context
    @EnvironmentObject var network: NetworkService
    @State var showPopup: Bool = false
    @State var listName = ""
    
    //init() {
    //    _viewModel = ObservedObject(wrappedValue: HomeViewModel())
    //}
    
    var body: some View{
        ZStack{
            NavigationView{
                VStack{
                    movieListsView
                }
                .navigationTitle("Movie Lists")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar{
                    ToolbarItem(placement: .navigationBarTrailing){
                        Button{
                            withAnimation{ showPopup.toggle() }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .popupNavigationView(horizontalPadding: 20, show: $showPopup){ newListPopup }
        }
        .onAppear {
                    print("APPEARED")
                    //viewModel.setup(db: db, network: network)
                }
    }
}

private extension Home {
    var movieListsView: some View {
        Group {
            if movieLists.isEmpty {
                Text("No Lists, Add one Now!")
            } else {
                List {
                    ForEach(movieLists, id: \.self) { movieList in
                        NavigationLink(movieList.name ?? "No Name", destination: Text("Test"))
                    }
                    .onDelete(perform: deleteList)
                    .padding(10)
                }
            }
        }
    }
    func closePopup() {
        withAnimation{ showPopup.toggle() }
    }
    
    func addNewList() {
        if listName.count > 0 {
            CDMovieList(name: listName, overview: "", context: context)
            withAnimation { showPopup.toggle() }
        }
    }
    
    func deleteList(at offsets: IndexSet) {
        withAnimation {
            offsets.forEach { index in
                let deleteItem = movieLists[index]
                CDMovieList.delete(movieList: deleteItem)
            }
        }
    }
    
    var newListPopup: some View {
            TextField("List Name:", text: $listName)
                .padding()
                .disableAutocorrection(true)
                .navigationTitle("Add New List")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { closePopup() }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Add") { addNewList() }
                    }
                }
        }
}


struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
            .environmentObject(NetworkService())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
