//
//  ExcelImportView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-24.
//

import SwiftUI
import UniformTypeIdentifiers

struct ExcelImportView: View {
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var existingLists: FetchedResults<CDMovieList>
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: AuthenticationViewModel

    private enum Step {
        case chooseFile
        case selectSheets([SpreadsheetSheet])
        case importing
        case finished([SheetResult])
    }

    /// Where the films go: a new list per sheet, or every chosen sheet into one existing list
    private enum Destination: Hashable {
        case newLists
        case existing(Int64)
    }

    /// What happened to one sheet, added up over its batches
    fileprivate struct SheetResult {
        let name: String
        var added = 0
        var alreadyInList = 0
        var skipped: [String] = []
    }

    @State private var step: Step = .chooseFile
    @State private var selected: Set<Int> = []
    @State private var destination: Destination = .newLists
    @State private var showFileImporter = false
    @State private var errorMessage: String?
    // Films sent so far out of all the chosen sheets', for the progress bar
    @State private var progress = (done: 0, total: 0)
    @State private var currentSheet = ""

    // The backend matches each batch on TMDb before answering, so small batches keep the progress bar moving
    private static let batchSize = 25

    private static let allowedTypes: [UTType] = [
        UTType(filenameExtension: "xlsx"),
        .commaSeparatedText,
        // Picked only to say they can't be read
        UTType(filenameExtension: "xls"),
    ].compactMap { $0 }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
                    .padding(.horizontal, 16)
            }
            .navigationTitle("Import from Excel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isImporting {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isImporting: Bool {
        if case .importing = step { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .chooseFile:
            chooseFileView
        case .selectSheets(let sheets):
            selectSheetsView(sheets)
        case .importing:
            importingView
        case .finished(let results):
            finishedView(results)
        }
    }
}

// MARK: - Steps

private extension ExcelImportView {
    var chooseFileView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Bring in a ranking or watch list you keep in a spreadsheet. Each sheet becomes a list, in the order of its rows.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 16) {
                instruction(1, "Put one film per row, with a **Title** column. Without headers, the first column is read as titles.")
                instruction(2, "Optional columns: **Year**, **Rank**, **Rating**, **Watched** (a date or yes) and **Notes**.")
                instruction(3, "Save it as **.xlsx** or **.csv**. Older .xls files need saving as .xlsx first.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            Spacer()

            Button {
                Haptics.tap()
                showFileImporter = true
            } label: {
                Label("Choose Spreadsheet", systemImage: "tablecells")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.bottom, 16)
        }
        .padding(.top, 16)
        .appearAnimation()
    }

    func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Theme.accentGradient)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func selectSheetsView(_ sheets: [SpreadsheetSheet]) -> some View {
        let filmCount = sheets.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.films.count }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    destinationPicker(sheets)
                        .padding(.top, 12)

                    HStack {
                        Text("\(sheets.count) \(sheets.count == 1 ? "sheet" : "sheets") found")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        if sheets.count > 1 {
                            Button(selected.count == sheets.count ? "Deselect All" : "Select All") {
                                Haptics.tap()
                                selected = selected.count == sheets.count ? [] : Set(sheets.map(\.id))
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentGradient)
                        }
                    }
                    .padding(.vertical, 12)

                    ForEach(sheets) { sheet in
                        sheetRow(sheet)
                    }
                }
                .padding(.bottom, 16)
            }

            Button("Import \(filmCount) \(filmCount == 1 ? "Film" : "Films")") {
                startImport(sheets.filter { selected.contains($0.id) })
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.5 : 1)
            .padding(.vertical, 16)
        }
    }

    func destinationPicker(_ sheets: [SpreadsheetSheet]) -> some View {
        Menu {
            Button {
                destination = .newLists
            } label: {
                Label(sheets.count == 1 ? "New List" : "A New List for Each Sheet", systemImage: "plus.rectangle.on.rectangle")
            }
            if !existingLists.isEmpty {
                Section("Add to an Existing List") {
                    ForEach(existingLists) { list in
                        Button(list.name ?? "Untitled") {
                            destination = .existing(list.id)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import into")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                    Text(destinationName(sheets))
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(14)
            .cardStyle(cornerRadius: 16)
        }
    }

    func sheetRow(_ sheet: SpreadsheetSheet) -> some View {
        let isSelected = selected.contains(sheet.id)
        return Button {
            Haptics.tap()
            if isSelected { selected.remove(sheet.id) } else { selected.insert(sheet.id) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(sheet.name)
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(sheet.films.count) \(sheet.films.count == 1 ? "film" : "films")")
                        if destination == .newLists && alreadyImported(sheet) {
                            Text("· Already in your lists")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    Text(columnSummary(sheet))
                        .font(.caption)
                        .foregroundColor(Theme.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .cardStyle(cornerRadius: 16)
        }
        .buttonStyle(PressableButtonStyle())
    }

    var importingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(Theme.accent)
            Text("Matching your films")
                .font(.title3.weight(.bold))
                .foregroundColor(Theme.textPrimary)
            Text(progress.done < progress.total ? "\(progress.done) of \(progress.total) from \(currentSheet)" : "Saving to your lists")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(Theme.textSecondary)
            Text("Each film is looked up on TMDb. Long sheets can take a few minutes, so keep the app open.")
                .font(.caption)
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    func finishedView(_ results: [SheetResult]) -> some View {
        let added = results.reduce(0) { $0 + $1.added }
        let alreadyInList = results.reduce(0) { $0 + $1.alreadyInList }
        let skipped = results.flatMap { result in result.skipped.map { (list: result.name, film: $0) } }
        var message = "Added \(added) \(added == 1 ? "film" : "films")"
        if case .newLists = destination {
            message += " to \(results.count) new \(results.count == 1 ? "list" : "lists")"
        }
        message += "."
        if alreadyInList > 0 {
            message += " \(alreadyInList) \(alreadyInList == 1 ? "was" : "were") already in the list."
        }

        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    EmptyStateView(
                        icon: "checkmark.seal.fill",
                        title: "Import complete",
                        message: message
                    )

                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(skipped.count) \(skipped.count == 1 ? "film" : "films") couldn't be matched")
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                            Text("Check the spelling and year in your spreadsheet, or add these yourself from the list.")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                            ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.film)
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    Text(item.list)
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }
                }
            }

            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.vertical, 16)
        }
    }
}

// MARK: - Actions

private extension ExcelImportView {
    func alreadyImported(_ sheet: SpreadsheetSheet) -> Bool {
        existingLists.contains { $0.name == sheet.name }
    }

    func destinationName(_ sheets: [SpreadsheetSheet]) -> String {
        if case .existing(let id) = destination, let list = existingLists.first(where: { $0.id == id }) {
            return list.name ?? "Untitled"
        }
        return sheets.count == 1 ? "New list “\(sheets[0].name)”" : "A new list for each sheet"
    }

    /// Which columns were found, e.g. "Title: Film · Year: Released · Ordered by Rank"
    func columnSummary(_ sheet: SpreadsheetSheet) -> String {
        guard let headers = sheet.headers else {
            return "No header row, so titles come from the first column" + (sheet.columns.year != nil ? " and years from the second." : ".")
        }
        let name = { (index: Int?) in index.flatMap { headers.indices.contains($0) ? headers[$0] : nil } }
        var parts = ["Title: \(name(sheet.columns.title) ?? "")"]
        if let year = name(sheet.columns.year) { parts.append("Year: \(year)") }
        if let watched = name(sheet.columns.watched) { parts.append("Watched: \(watched)") }
        if let notes = name(sheet.columns.notes) { parts.append("Notes: \(notes)") }
        if let rank = name(sheet.columns.rank) {
            parts.append("Ordered by \(rank)")
        } else if let rating = name(sheet.columns.rating) {
            parts.append("Best \(rating) first")
        }
        return parts.joined(separator: " · ")
    }

    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let sheets = try SpreadsheetImport.sheets(from: url)
                // Skip sheets that look like they came over in an earlier import
                let fresh = sheets.filter { !alreadyImported($0) }
                selected = Set((fresh.isEmpty ? sheets : fresh).map(\.id))
                destination = .newLists
                withAnimation(Theme.spring) {
                    step = .selectSheets(sheets)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func startImport(_ sheets: [SpreadsheetSheet]) {
        guard let userID = viewModel.user?.uid else {
            errorMessage = "You need to be signed in to import lists."
            return
        }
        let previousStep = step
        let existingID: Int64? = {
            if case .existing(let id) = destination { return id }
            return nil
        }()
        progress = (0, sheets.reduce(0) { $0 + $1.films.count })
        withAnimation(Theme.spring) {
            step = .importing
        }

        Task { @MainActor in
            var results: [SheetResult] = []
            var failed = false
            for sheet in sheets {
                currentSheet = sheet.name
                var result = SheetResult(name: sheet.name)
                var listID = existingID
                for start in stride(from: 0, to: sheet.films.count, by: Self.batchSize) {
                    let batch = Array(sheet.films[start..<min(start + Self.batchSize, sheet.films.count)])
                    do {
                        // The first batch of a new list creates it; the rest go into it by id
                        let response = try await importBatch(listID: listID, name: listID == nil ? sheet.name : nil, films: batch)
                        listID = response.list_id
                        result.added += response.added
                        result.alreadyInList += response.already_in_list
                        result.skipped += response.skipped
                        progress.done += batch.count
                    } catch {
                        print("Excel import failed:", error.localizedDescription)
                        failed = true
                        break
                    }
                }
                // A new list whose first batch failed was never made
                if listID != nil { results.append(result) }
                if failed { break }
            }

            guard !results.isEmpty else {
                errorMessage = "Something went wrong while importing. Check your connection and try again."
                withAnimation(Theme.spring) {
                    step = previousStep
                }
                return
            }

            // The server has the films in order, with watched dates and notes, so the lists come back from a sync
            progress.done = progress.total
            SyncStatus.shared.sync(firebaseID: userID) {
                if failed {
                    errorMessage = "The import stopped partway, so some films weren't added. Check your connection and import into the same list again; films already in it are skipped."
                } else {
                    // TODO(#109): log import_completed + review prompt
                    Haptics.success()
                }
                withAnimation(Theme.spring) {
                    step = .finished(results)
                }
            }
        }
    }

    func importBatch(listID: Int64?, name: String?, films: [SpreadsheetFilm]) async throws -> SpreadsheetImportResponse {
        try await withCheckedThrowingContinuation { continuation in
            APIService.shared.importSpreadsheetFilms(listID: listID, name: name, films: films) { result in
                continuation.resume(with: result)
            }
        }
    }
}

struct ExcelImportView_Previews: PreviewProvider {
    static var previews: some View {
        ExcelImportView()
            .environmentObject(AuthenticationViewModel())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
