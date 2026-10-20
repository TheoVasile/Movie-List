//
//  ContactsFinder.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import Contacts
import CryptoKit

/// Finds which of the user's contacts are on CineList. Each contact's emails and phone numbers are turned into
/// SHA-256 hashes on the phone and only the hashes are sent; the server compares them with its own and keeps
/// nothing. Names and other contact details never leave the phone
enum ContactsFinder {
    enum Failure: Error {
        case denied
        case failed
    }

    /// Whether the user has already let CineList read contacts, so it can check again without asking
    static var wasAllowed: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// An email as the server hashes it: trimmed and lowercased
    static func hash(email: String) -> String {
        sha256(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// A phone number's last 10 digits, so "+1 (416) 555-0100" and "416-555-0100" match. nil if it's too short to
    /// be a phone number
    static func hash(phone: String) -> String? {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return sha256(String(digits.suffix(10)))
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Asks for access to contacts the first time, then calls back on the main thread with the people found
    static func findFriends(completion: @escaping (Result<[UserSummary], Failure>) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { completion(.failure(.denied)) }
                return
            }
            var emails = Set<String>()
            var phones = Set<String>()
            let request = CNContactFetchRequest(keysToFetch: [CNContactEmailAddressesKey as CNKeyDescriptor,
                                                              CNContactPhoneNumbersKey as CNKeyDescriptor])
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    contact.emailAddresses.forEach { emails.insert(hash(email: $0.value as String)) }
                    contact.phoneNumbers.forEach { number in
                        if let hashed = hash(phone: number.value.stringValue) { phones.insert(hashed) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(.failed)) }
                return
            }
            APIService.shared.matchContacts(emails: Array(emails), phones: Array(phones)) { result in
                switch result {
                case .success(let people): completion(.success(people))
                case .failure: completion(.failure(.failed))
                }
            }
        }
    }
}
