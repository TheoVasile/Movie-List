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
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @EnvironmentObject var network: NetworkService
    @State var showPopup: Bool = false
    @State var listName = ""
    @State var showFileSelector: Bool = false
    
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
                        Menu {
                            Button("Add") {
                                withAnimation{ showPopup.toggle() }
                            }
                            Button("Import") {
                                showFileSelector = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .overlay {
                if showFileSelector {
                    ExcelFilePickerView(showFileSelector: $showFileSelector)
                }
            }
            .popupNavigationView(horizontalPadding: 20, show: $showPopup){ newListPopup }
        }
    }
}

private extension Home {
    var movieListsView: some View {
        Group {
            if movieLists.isEmpty {
                List{
                    Text("No Lists, Add one Now!")
                }
            } else {
                List {
                    ForEach(movieLists, id: \.self) { movieList in
                        NavigationLink(movieList.name ?? "No Name", destination:
                                        ListView(movieList: movieList, context: context)
                            .environmentObject(NetworkService())
                            .environmentObject(DatabaseService())
                        )
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
            let newList = CDMovieList(id: Int64(1), name: listName, overview: "", context: context)
            
            APIService.shared.createList(
                    userID: viewModel.user!.uid,
                    name: listName,
                    overview: "",
                    isRanked: true
                ) { result in
                    switch result {
                    case .success(let serverList):
                        print("✅ List synced to backend:", serverList)

                        // Optionally, update Core Data with the server ID
                        DispatchQueue.main.async {
                            newList.id = serverList.id // Replace with backend ID
                            try? context.save()
                        }

                    case .failure(let error):
                        print(viewModel.user?.uid ?? "no uid")
                        print("❌ Backend request failed, deleting from Core Data:", error.localizedDescription)

                        // Step 3: If request fails, delete the local entry
                        DispatchQueue.main.async {
                            context.delete(newList)
                            try? context.save()
                        }
                    }
                }
            
            withAnimation { showPopup.toggle() }
        }
    }
    
    func deleteList(at offsets: IndexSet) {
        withAnimation {
            offsets.forEach { index in
                let deleteItem = movieLists[index]
                APIService.shared.deleteList(listID: deleteItem.id) { result in
                        switch result {
                        case .success(let serverList):
                            print("✅ List synced to backend:", serverList)
                            CDMovieList.delete(movieList: deleteItem)

                        case .failure(let error):
                            print("❌ Backend request failed", error.localizedDescription)
                        }
                    }
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
            .environmentObject(AuthenticationViewModel())
            .environmentObject(NetworkService())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
