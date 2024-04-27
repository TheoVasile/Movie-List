//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @EnvironmentObject var network: Network
    @EnvironmentObject var db: DataAccess
    @ObservedObject var viewModel: HomeViewModel
    @State var showPopup: Bool = false
    @State var listName = ""
    
    init() {
        _viewModel = ObservedObject(wrappedValue: HomeViewModel())
    }
    
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
                NavigationLink(list, destination: ListView(listName: list))
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

class HomeViewModel: ObservableObject {
    @Published var lists: [String] = []
    var db: DataAccess? = nil
    var network: Network? = nil
    
    init(){ }
    
    func setup(db: DataAccess, network: Network) {
        self.db = db
        self.network = network
        self.loadLists()
        print("setup")
    }
    
    func loadLists() {
        lists = db?.getLists() ?? []
        print(lists)
    }
    
    func addList(named name: String) {
        if name.count > 0 {
            lists.append(name)
            if (db?.addList(list: name) ?? -1) < 0 {
                print("failed to add list")
            }
        }
    }
    
    func deleteList(at offsets: IndexSet) {
        if (db?.deleteList(list: lists[offsets.first ?? 0]) ?? -1) < 0 {
            print("Failed to delete list")
        }
    }
}

struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
            .environmentObject(Network())
            .environmentObject(DataAccess())
    }
}
