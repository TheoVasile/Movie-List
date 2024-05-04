//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @EnvironmentObject var network: NetworkService
    @EnvironmentObject var db: DatabaseService
    @ObservedObject var viewModel: HomeViewModel
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
                    viewModel.setup(db: db, network: network)
                }
    }
}

private extension Home {
    var movieListsView: some View {
        Group {
            if viewModel.lists.isEmpty {
                Text("No Lists, Add one Now!")
            } else {
                movieLists
            }
        }
    }
    var movieLists: some View {
        List {
            ForEach(viewModel.lists, id: \.self) { list in
                NavigationLink(list, destination: ListView(viewModel: ListViewModel(listName: listName)))
            }
            .onDelete(perform: viewModel.deleteList)
            .padding(10)
        }
    }
    
    func closePopup() {
        withAnimation{ showPopup.toggle() }
    }
    
    func addNewList() {
        if listName.count > 0 {
            viewModel.addList(named: listName)
            withAnimation { showPopup.toggle() }
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
        Home(viewModel: HomeViewModel())
            .environmentObject(NetworkService())
            .environmentObject(DatabaseService())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
