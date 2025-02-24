//
//  ExcelFilePickerView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-24.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreXLSX

struct ExcelFilePickerView: View {
    @State private var fileURL: URL?
    @State private var extractedData: [[String]] = []
    @Binding var showFileSelector: Bool
    
    var body: some View {
        Color.clear // Invisible view
            .fileImporter(
                isPresented: $showFileSelector,
                allowedContentTypes: [UTType.data],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .onAppear {
                showFileSelector = true // Automatically open file picker
            }
    }
    
    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let pickedFileURL = urls.first {
                fileURL = pickedFileURL
                extractData(from: pickedFileURL)
            }
        case .failure(let error):
            print("File selection error: \(error.localizedDescription)")
        }
    }
    
    func extractData(from fileURL: URL) {
        do {
            let fileData = try Data(contentsOf: fileURL)
            guard let archive = try? XLSXFile(data: fileData) else { return }
            
            var newExtractedData: [[String]] = []
            for path in try archive.parseWorksheetPaths() {
                let worksheet = try archive.parseWorksheet(at: path)
                let sharedStrings = (try archive.parseSharedStrings())!
                
                for row in worksheet.data?.rows ?? [] {
                    let rowData = row.cells.compactMap { cell in
                        cell.stringValue(sharedStrings)
                    }
                    newExtractedData.append(rowData)
                }
            }
            
            extractedData = newExtractedData
        } catch {
            print("Error reading Excel file: \(error.localizedDescription)")
        }
    }
}

struct ExcelFilePickerView_Previews : PreviewProvider {
    static var previews: some View {
        ExcelFilePickerView(showFileSelector: .constant(true))
    }
}
