//
//  HomeViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation


class HomeViewModel: ObservableObject {
    @Published var lists: [String] = []
    var db: DatabaseService? = nil
    var network: NetworkService? = nil
    
    init(){ }
    
    func setup(db: DatabaseService, network: NetworkService) {
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
