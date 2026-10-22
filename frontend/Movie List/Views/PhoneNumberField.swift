//
//  PhoneNumberField.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-22.
//

import Foundation
import SwiftUI
import FirebaseAuth

/// A country and its calling code, for the phone number's country picker
struct PhoneCountry: Identifiable, Hashable {
    let region: String
    let dialCode: String

    var id: String { region }

    var name: String {
        Locale.current.localizedString(forRegionCode: region) ?? region
    }

    var flag: String {
        region.unicodeScalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init)
            .joined()
    }

    // Calling codes by region. Countries sharing +1 or +7 are listed separately so each can be picked by name
    private static let dialCodes: [String: String] = [
        "AE": "971", "AR": "54", "AT": "43", "AU": "61", "BD": "880", "BE": "32", "BG": "359", "BR": "55",
        "CA": "1", "CH": "41", "CL": "56", "CN": "86", "CO": "57", "CR": "506", "CY": "357", "CZ": "420",
        "DE": "49", "DK": "45", "DO": "1", "DZ": "213", "EC": "593", "EE": "372", "EG": "20", "ES": "34",
        "FI": "358", "FR": "33", "GB": "44", "GH": "233", "GR": "30", "GT": "502", "HK": "852", "HR": "385",
        "HU": "36", "ID": "62", "IE": "353", "IL": "972", "IN": "91", "IQ": "964", "IR": "98", "IS": "354",
        "IT": "39", "JM": "1", "JO": "962", "JP": "81", "KE": "254", "KR": "82", "KW": "965", "KZ": "7",
        "LB": "961", "LK": "94", "LT": "370", "LU": "352", "LV": "371", "MA": "212", "MD": "373", "MX": "52",
        "MY": "60", "NG": "234", "NL": "31", "NO": "47", "NP": "977", "NZ": "64", "PA": "507", "PE": "51",
        "PH": "63", "PK": "92", "PL": "48", "PR": "1", "PT": "351", "QA": "974", "RO": "40", "RS": "381",
        "RU": "7", "SA": "966", "SE": "46", "SG": "65", "SI": "386", "SK": "421", "TH": "66", "TN": "216",
        "TR": "90", "TT": "1", "TW": "886", "UA": "380", "US": "1", "UY": "598", "VE": "58", "VN": "84",
        "ZA": "27",
    ]

    static let all: [PhoneCountry] = dialCodes
        .map { PhoneCountry(region: $0.key, dialCode: $0.value) }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    /// The country this iPhone is set to, or the US
    static var current: PhoneCountry {
        let region = Locale.current.region?.identifier ?? "US"
        return all.first { $0.region == region } ?? all.first { $0.region == "US" }!
    }

    /// The number in international format, e.g. "416 555 0100" in Canada -> "+14165550100". A leading 0 (the
    /// trunk prefix many countries dial within the country) is dropped; a number typed with + is taken as it is
    func international(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("+") { return "+" + digits }
        let national = digits.hasPrefix("0") ? String(digits.drop { $0 == "0" }) : digits
        return "+" + dialCode + national
    }
}

/// Adds, changes or removes the user's phone number, which lets friends who sync their contacts find them.
/// The number is verified with a code sent by text before it's saved. Used in Settings and in Find People
struct PhoneNumberField: View {
    private enum Step: Equatable {
        case number
        // A code has been sent; the id goes back to Firebase with the code
        case code(verificationID: String, phone: String)
    }

    @ObservedObject private var social = SocialStore.shared
    @State private var country = PhoneCountry.current
    @State private var number = ""
    @State private var code = ""
    @State private var step = Step.number
    @State private var isChanging = false
    @State private var isWorking = false
    @State private var message: String? = nil
    @State private var confirmRemove = false
    @FocusState private var focused: Bool

    private var savedPhone: String? {
        social.profile?.has_phone == true ? (social.profile?.phone ?? "Added") : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let savedPhone, !isChanging {
                savedRow(savedPhone)
            } else {
                switch step {
                case .number:
                    numberEntry
                case .code(let verificationID, let phone):
                    codeEntry(verificationID: verificationID, phone: phone)
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(Theme.accentSecondary)
            }
        }
        .confirmationDialog("Remove your phone number?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("Friends will no longer find you by phone number. They can still find you by email or @username.")
        }
    }

    private func savedRow(_ phone: String) -> some View {
        HStack {
            Label {
                Text(phone)
                    .foregroundColor(Theme.textPrimary)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.accentGradient)
            }
            .accessibilityLabel("\(phone), verified")
            Spacer()
            if isWorking {
                ProgressView()
            } else {
                Button("Change") {
                    number = ""
                    message = nil
                    withAnimation(Theme.spring) { isChanging = true }
                    focused = true
                }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.accent)
                Button("Remove", role: .destructive) { confirmRemove = true }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var numberEntry: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Country", selection: $country) {
                    ForEach(PhoneCountry.all) { option in
                        Text("\(option.flag) \(option.name) +\(option.dialCode)").tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(country.flag) +\(country.dialCode)")
                        .foregroundColor(Theme.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.textTertiary)
                }
                .fixedSize()
            }
            .accessibilityLabel("Country code: \(country.name), +\(country.dialCode)")
            .disabled(isWorking)
            TextField("Phone number", text: $number)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focused)
                .disabled(isWorking)
            if isWorking {
                ProgressView()
            } else {
                if isChanging {
                    Button("Cancel") {
                        message = nil
                        withAnimation(Theme.spring) { isChanging = false }
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.textSecondary)
                }
                Button("Send Code", action: sendCode)
                    .bold()
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.accent)
                    .disabled(number.filter(\.isNumber).count < 6)
                    .opacity(number.filter(\.isNumber).count < 6 ? 0.4 : 1)
            }
        }
    }

    private func codeEntry(verificationID: String, phone: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter the 6-digit code sent to \(phone).")
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
            HStack(spacing: 10) {
                Image(systemName: "number")
                    .foregroundColor(Theme.textSecondary)
                TextField("Code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .disabled(isWorking)
                if isWorking {
                    ProgressView()
                } else {
                    Button("Back") {
                        message = nil
                        withAnimation(Theme.spring) { step = .number }
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.textSecondary)
                    Button("Verify") { verify(verificationID: verificationID) }
                        .bold()
                        .buttonStyle(.borderless)
                        .foregroundColor(Theme.accent)
                        .disabled(code.filter(\.isNumber).count < 6)
                        .opacity(code.filter(\.isNumber).count < 6 ? 0.4 : 1)
                }
            }
        }
    }

    // Firebase texts a code to the number; the number isn't saved anywhere until the code is checked
    private func sendCode() {
        let phone = country.international(number)
        focused = false
        isWorking = true
        message = nil
        PhoneAuthProvider.provider().verifyPhoneNumber(phone, uiDelegate: nil) { verificationID, error in
            DispatchQueue.main.async {
                isWorking = false
                guard let verificationID else {
                    message = Self.describe(error)
                    return
                }
                code = ""
                withAnimation(Theme.spring) { step = .code(verificationID: verificationID, phone: phone) }
                focused = true
            }
        }
    }

    // A correct code adds the number to the user's Firebase account, then the server copies it from there
    private func verify(verificationID: String) {
        guard let user = Auth.auth().currentUser else { return }
        let credential = PhoneAuthProvider.provider().credential(withVerificationID: verificationID,
                                                                 verificationCode: code.filter(\.isNumber))
        focused = false
        isWorking = true
        message = nil
        user.updatePhoneNumber(credential) { error in
            if let error {
                DispatchQueue.main.async {
                    isWorking = false
                    message = Self.describe(error)
                }
                return
            }
            APIService.shared.savePhoneVerified { result in
                isWorking = false
                switch result {
                case .success:
                    Haptics.success()
                    SocialStore.shared.load()
                    withAnimation(Theme.spring) {
                        isChanging = false
                        step = .number
                    }
                case .failure(let error):
                    message = (error as NSError).code == 409
                        ? "That number is already on another CineList account."
                        : "Your number was verified but couldn't be saved. Try again."
                }
            }
        }
    }

    private func remove() {
        isWorking = true
        message = nil
        APIService.shared.removePhone { removed in
            isWorking = false
            if removed {
                SocialStore.shared.load()
            } else {
                message = "Couldn't remove your phone number. Try again."
            }
        }
    }

    private static func describe(_ error: Error?) -> String {
        // The Firebase project can't send texts until billing is set up for it
        if let error, "\(error)".contains("BILLING_NOT_ENABLED") {
            return "Texting codes isn't set up yet, so numbers can't be verified right now."
        }
        switch (error as NSError?).flatMap({ AuthErrorCode(rawValue: $0.code) }) {
        case .invalidPhoneNumber:
            return "That doesn't look like a phone number. Check the country code too."
        case .invalidVerificationCode, .missingVerificationCode:
            return "That code isn't right. Check the text and try again."
        case .sessionExpired:
            return "That code has expired. Go back and send a new one."
        case .credentialAlreadyInUse:
            return "That number is already on another CineList account."
        case .tooManyRequests, .quotaExceeded:
            return "Too many tries. Wait a while and try again."
        case .operationNotAllowed:
            return "Adding phone numbers isn't available right now."
        default:
            return "Something went wrong. Try again."
        }
    }
}
