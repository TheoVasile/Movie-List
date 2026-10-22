//
//  PhoneNumberField.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-22.
//

import Foundation
import SwiftUI

/// The user's own phone number, which lets friends who sync their contacts find them. The server only keeps a
/// scrambled (hashed) version, so the number itself is remembered on this device just to show it back
enum PhoneNumber {
    private static let displayKey = "phone.display"

    static var saved: String? {
        UserDefaults.standard.string(forKey: displayKey)
    }

    /// Saves a number, or removes it with nil. Calls back with an error message, or nil once it's saved
    static func save(_ number: String?, completion: @escaping (String?) -> Void) {
        let hash: String?
        if let number {
            guard let hashed = ContactsFinder.hash(phone: number) else {
                completion("That doesn't look like a phone number.")
                return
            }
            hash = hashed
        } else {
            hash = nil
        }
        APIService.shared.setPhoneHash(hash) { saved in
            DispatchQueue.main.async {
                guard saved else {
                    completion("Couldn't save your phone number. Try again.")
                    return
                }
                let trimmed = number?.trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(trimmed, forKey: displayKey)
                SocialStore.shared.load()
                completion(nil)
            }
        }
    }
}

/// Adds, changes or removes the user's phone number. Used in Settings and when syncing contacts
struct PhoneNumberField: View {
    @ObservedObject private var social = SocialStore.shared
    @State private var number = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var message: String? = nil
    @State private var confirmRemove = false
    @FocusState private var focused: Bool

    private var hasPhone: Bool { social.profile?.has_phone == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasPhone && !isEditing {
                HStack {
                    Label(PhoneNumber.saved ?? "Added", systemImage: "phone.fill")
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("Change") {
                        number = PhoneNumber.saved ?? ""
                        withAnimation(Theme.spring) { isEditing = true }
                        focused = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.accent)
                    Button("Remove", role: .destructive) { confirmRemove = true }
                        .buttonStyle(.borderless)
                }
            } else {
                HStack {
                    Image(systemName: "phone")
                        .foregroundColor(Theme.textSecondary)
                    TextField("Your phone number", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($focused)
                        .disabled(isSaving)
                    if isSaving {
                        ProgressView()
                    } else {
                        if isEditing {
                            Button("Cancel") {
                                withAnimation(Theme.spring) { isEditing = false }
                                message = nil
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(Theme.textSecondary)
                        }
                        Button("Save", action: save)
                            .bold()
                            .buttonStyle(.borderless)
                            .foregroundColor(Theme.accent)
                            .disabled(number.filter(\.isNumber).count < 7)
                            .opacity(number.filter(\.isNumber).count < 7 ? 0.4 : 1)
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(Theme.accentSecondary)
            }
        }
        .confirmationDialog("Remove your phone number?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                isSaving = true
                PhoneNumber.save(nil) { error in
                    isSaving = false
                    message = error
                }
            }
        } message: {
            Text("Friends will no longer find you by phone number. They can still find you by email or @username.")
        }
    }

    private func save() {
        focused = false
        isSaving = true
        message = nil
        PhoneNumber.save(number) { error in
            isSaving = false
            message = error
            if error == nil {
                Haptics.success()
                withAnimation(Theme.spring) { isEditing = false }
            }
        }
    }
}
