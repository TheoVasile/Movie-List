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
    // The export ZIP waiting to go to the share sheet
    @State private var exportItem: ShareItem? = nil
    @State var showPopup: Bool = false
    @State var listName = ""
    @State var showFileSelector: Bool = false
    @State var showLetterboxdImport: Bool = false
    
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View{
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        movieListsView
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Your Lists")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Haptics.tap()
                            showPopup = true
                        } label: {
                            Label("New List", systemImage: "plus.rectangle.on.rectangle")
                        }
                        Button {
                            showFileSelector = true
                        } label: {
                            Label("Import from Excel", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            Haptics.tap()
                            showLetterboxdImport = true
                        } label: {
                            Label("Import from Letterboxd", systemImage: "film.stack")
                        }
                        if !movieLists.isEmpty {
                            Divider()
                            Button {
                                exportAllLists()
                            } label: {
                                Label("Export All Lists (ZIP)", systemImage: "doc.zipper")
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accentGradient)
                    }
                }
            }
        }
        .overlay {
            if showFileSelector {
                ExcelFilePickerView(showFileSelector: $showFileSelector)
            }
        }
        .sheet(isPresented: $showPopup) {
            newListSheet
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLetterboxdImport) {
            LetterboxdImportView()
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, context)
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
    }
}

private extension Home {
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(Theme.accentGradient)
            Text(movieLists.isEmpty
                 ? "Start your first collection"
                 : "\(movieLists.count) \(movieLists.count == 1 ? "list" : "lists") · \(totalMovies) films ranked")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.top, 4)
        .appearAnimation()
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        // displayName falls back to the email address, which reads badly in a greeting
        let name = viewModel.user?.displayName ?? ""
        let firstName = name.contains("@") ? "" : name.split(separator: " ").first.map(String.init) ?? ""
        let timeOfDay = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return firstName.isEmpty ? timeOfDay : "\(timeOfDay), \(firstName)"
    }

    var totalMovies: Int {
        movieLists.reduce(0) { $0 + $1.movies.count }
    }

    var movieListsView: some View {
        Group {
            if movieLists.isEmpty {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No lists yet",
                    message: "Create a list and start ranking the films you love.",
                    actionTitle: "Create a List"
                ) {
                    showPopup = true
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(movieLists.enumerated()), id: \.element) { index, movieList in
                        NavigationLink {
                            ListView(movieList: movieList, context: context)
                                .environmentObject(NetworkService())
                                .environmentObject(DatabaseService())
                        } label: {
                            ListCard(movieList: movieList)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteList(movieList)
                            } label: {
                                Label("Delete List", systemImage: "trash")
                            }
                        }
                        .appearAnimation(delay: Double(min(index, 8)) * 0.06)
                    }
                }
            }
        }
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
                        print("List synced to backend:", serverList)

                        // Optionally, update Core Data with the server ID
                        DispatchQueue.main.async {
                            newList.id = serverList.id // Replace with backend ID
                            try? context.save()
                        }

                    case .failure(let error):
                        print(viewModel.user?.uid ?? "no uid")
                        print("Backend request failed, deleting from Core Data:", error.localizedDescription)

                        // Step 3: If request fails, delete the local entry
                        DispatchQueue.main.async {
                            withAnimation(Theme.spring) {
                                context.delete(newList)
                                try? context.save()
                            }
                        }
                    }
                }
            
            Haptics.success()
            listName = ""
            showPopup = false
        }
    }
    
    /// Every list in one ZIP, laid out like Letterboxd's data export
    func exportAllLists() {
        Haptics.tap()
        do {
            exportItem = ShareItem(items: [try ListExport.makeZip(lists: Array(movieLists))])
        } catch {
            print("Error exporting lists:", error)
        }
    }

    func deleteList(_ deleteItem: CDMovieList) {
        APIService.shared.deleteList(listID: deleteItem.id) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let serverList):
                    print("List synced to backend:", serverList)
                    withAnimation(Theme.spring) {
                        CDMovieList.delete(movieList: deleteItem)
                    }

                case .failure(let error):
                    print("Backend request failed", error.localizedDescription)
                }
            }
        }
    }
    
    var newListSheet: some View {
        ZStack {
            Theme.surface.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("New List")
                    .font(.title2.weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 12) {
                    Image(systemName: "list.star")
                        .foregroundStyle(Theme.accentGradient)
                    TextField("e.g. Christmas Classics", text: $listName)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit { addNewList() }
                }
                .padding(16)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button("Create List") { addNewList() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(listName.isEmpty)
                    .opacity(listName.isEmpty ? 0.5 : 1)
                    .animation(.easeOut(duration: 0.2), value: listName.isEmpty)
            }
            .padding(24)
        }
    }
}

// MARK: - List card

private struct ListCard: View {
    @ObservedObject var movieList: CDMovieList

    private var topPosters: [String?] {
        movieList.movies
            .sorted { $0.rank < $1.rank }
            .prefix(3)
            .map { $0.poster_path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            posterFan
                .frame(height: 150)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(movieList.name ?? "No Name")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(movieList.movies.count) \(movieList.movies.count == 1 ? "film" : "films")")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(
            ZStack {
                Theme.surface
                PosterBackdrop(path: topPosters.first ?? nil)
                    .opacity(0.6)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: Theme.shadow.opacity(0.35), radius: 12, y: 8)
    }

    // Top three films fanned out like a hand of cards, #1 in front
    private var posterFan: some View {
        ZStack {
            if topPosters.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .frame(width: 90, height: 135)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(Theme.textTertiary)
                    )
            } else {
                ForEach(Array(topPosters.enumerated().reversed()), id: \.offset) { index, path in
                    PosterImage(path: path, cornerRadius: 10, size: .medium)
                        .frame(width: 90, height: 135)
                        .shadow(color: Theme.shadow.opacity(0.5), radius: 8, y: 4)
                        .rotationEffect(.degrees(Double(index) * (index.isMultiple(of: 2) ? 9 : -9)))
                        .offset(x: CGFloat(index) * (index.isMultiple(of: 2) ? 22 : -22), y: CGFloat(index) * 4)
                        .scaleEffect(1 - CGFloat(index) * 0.08)
                }
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
