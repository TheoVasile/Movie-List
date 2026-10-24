//
//  AuthenticationViewModel.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import FirebaseCore
import FirebaseAuth
import GoogleSignIn
import GoogleSignInSwift
import AuthenticationServices
import CryptoKit
import CoreData
import WidgetKit

enum AuthenticationState {
  case unauthenticated
  case authenticating
  case authenticated
}

enum AuthenticationFlow {
  case login
  case signUp
}

@MainActor
class AuthenticationViewModel: ObservableObject {
  @Published var email: String = ""
  @Published var password: String = ""
  @Published var confirmPassword: String = ""

  @Published var flow: AuthenticationFlow = .login

  @Published var isValid: Bool  = false
  @Published var authenticationState: AuthenticationState = .unauthenticated
  @Published var errorMessage: String = ""
  @Published var user: User?
  @Published var displayName: String = ""
  // The nonce for the Apple sign-in in progress, whose hash went to Apple
  var appleNonce: String?

  init() {
    registerAuthStateHandler()

    $flow
      .combineLatest($email, $password, $confirmPassword)
      .map { flow, email, password, confirmPassword in
        flow == .login
        ? !(email.isEmpty || password.isEmpty)
        : !(email.isEmpty || password.isEmpty || confirmPassword.isEmpty)
      }
      .assign(to: &$isValid)
  }

  private var authStateHandler: AuthStateDidChangeListenerHandle?

  func registerAuthStateHandler() {
    if authStateHandler == nil {
      authStateHandler = Auth.auth().addStateDidChangeListener { auth, user in
        self.user = user
        self.authenticationState = user == nil ? .unauthenticated : .authenticated
        // An Apple Hide My Email address means nothing to them, so their name is shown instead
        self.displayName = self.shownEmail ?? user?.displayName ?? ""
      }
    }
  }

  func switchFlow() {
    flow = flow == .login ? .signUp : .login
    errorMessage = ""
  }

  private func wait() async {
    do {
      print("Wait")
      try await Task.sleep(nanoseconds: 1_000_000_000)
      print("Done")
    }
    catch { }
  }

  func reset() {
    flow = .login
    email = ""
    password = ""
    confirmPassword = ""
  }
}

extension AuthenticationViewModel {
  func signInWithEmailPassword() async -> Bool {
    authenticationState = .authenticating
    do {
        let firebaseUser = try await Auth.auth().signIn(withEmail: self.email, password: self.password)
        PersistenceController.shared.fetchAllCoreDataObjects(firebase_id: firebaseUser.user.uid)
        AppAnalytics.log(.signIn(.email))
        return true
    }
    catch  {
      print(error)
      errorMessage = error.localizedDescription
      authenticationState = .unauthenticated
      return false
    }
  }

    func signUpWithEmailPassword(name: String, handle: String) async -> Bool {
        authenticationState = .authenticating
        do  {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let firebaseUser = result.user
            // The name typed at sign-up is the one shown on Home, Profile and to friends
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = (firebaseUser.email ?? "").components(separatedBy: "@").first ?? ""
            let displayName = name.isEmpty ? fallback : name
            let change = firebaseUser.createProfileChangeRequest()
            change.displayName = displayName
            try? await change.commitChanges()
            self.user = Auth.auth().currentUser
            AppAnalytics.log(.signUp(.email))
            
            APIService.shared.createUser(firebase_id: firebaseUser.uid, email: firebaseUser.email ?? "no email", name: displayName,
                                         handle: handle) { result in
                if case .failure(let error) = result { print(error.localizedDescription) }
                // The account exists now; if the username didn't save, the app asks for one before going on
                SocialStore.shared.load()
            }
            
            return true
        }
        catch {
            print(error)
            errorMessage = error.localizedDescription
            authenticationState = .unauthenticated
            return false
        }
    }

    func signOut() {
    do {
        // Before signing out, while the request can still be signed in
        NotificationManager.shared.unregisterDevice()
        // Stops watching for movie theatres and forgets the ones found
        TheatreCheckIns.shared.setEnabled(false)
        PersistenceController.shared.deleteAllCoreDataObjects()
        SyncStatus.shared.reset()
        SocialStore.shared.reset()
        // The next person to sign in shouldn't see this account's films on the Home Screen
        WidgetSnapshot.remove()
        WidgetCenter.shared.reloadAllTimelines()
        // The birthday is saved with the account and comes back when it signs in again; the next person to
        // sign in shouldn't get it
        UserDefaults.standard.removeObject(forKey: Personalization.birthdayKey)
      try Auth.auth().signOut()
    }
    catch {
      print(error)
      errorMessage = error.localizedDescription
    }
  }

  /// Emails a password reset link. Returns nil once it's sent, or a message to show the user
  func sendPasswordReset(to email: String) async -> String? {
    let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else { return "Enter the email you signed up with." }
    do {
      try await Auth.auth().sendPasswordReset(withEmail: email)
      return nil
    }
    catch {
      switch AuthErrorCode(rawValue: (error as NSError).code) {
      case .invalidEmail:
        return "That doesn't look like an email address."
      case .networkError:
        return "Couldn't reach the server. Check your connection and try again."
      case .tooManyRequests:
        return "Too many attempts. Wait a few minutes and try again."
      default:
        // Unknown accounts aren't reported, so nobody can use this to find out who has an account
        return nil
      }
    }
  }

  /// Changes the user's name on their account and on the server. Returns nil once saved, or a message to show
  func updateName(_ name: String) async -> String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 40 else { return "Names are 1 to 40 characters." }
    guard let current = Auth.auth().currentUser else { return "You're not signed in." }
    do {
      let change = current.createProfileChangeRequest()
      change.displayName = name
      try await change.commitChanges()
      try await current.reload()
    } catch {
      return "Couldn't save your name. Try again."
    }
    // Firebase updates the same User object, so publish it again for screens showing the name
    user = Auth.auth().currentUser
    objectWillChange.send()
    return await withCheckedContinuation { continuation in
      APIService.shared.setDisplayName(name) { saved in
        continuation.resume(returning: saved ? nil : "Saved on this account, but friends may still see your old name. Try again later.")
      }
    }
  }

  /// Whether the account has a password, so deleting it is confirmed with that rather than with Google or Apple
  var signsInWithPassword: Bool {
    user?.providerData.contains { $0.providerID == EmailAuthProviderID } ?? false
  }

  /// Whether the account signs in with Apple, so deleting it is confirmed with Apple and its access revoked
  var signsInWithApple: Bool {
    user?.providerData.contains { $0.providerID == "apple.com" } ?? false
  }

  /// The account's email to show, or nil when there's none or it's an Apple Hide My Email address, which means
  /// nothing to the user
  var shownEmail: String? {
    guard let email = user?.email, !email.isEmpty, !email.hasSuffix("@privaterelay.appleid.com") else { return nil }
    return email
  }

  /// Permanently deletes the account. The user confirms it's them first, with their password or (when password is
  /// nil) their Apple or Google account, since the server only deletes accounts signed in to in the last few
  /// minutes. The server then deletes their data and their sign-in in one go, so neither is left without the other
  func deleteAccount(password: String?) async -> AccountDeletionResult {
    guard let current = Auth.auth().currentUser else { return .failed("You're not signed in.") }
    // Apple's one-time code from signing in again, used to revoke Marquee's access to the Apple ID
    var appleAuthorizationCode: String? = nil
    do {
      let credential: AuthCredential
      if let password {
        credential = EmailAuthProvider.credential(withEmail: current.email ?? "", password: password)
      } else if signsInWithApple {
        let apple = try await AppleSignIn().signIn()
        credential = try appleCredential(from: apple.credential, nonce: apple.nonce)
        appleAuthorizationCode = apple.credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
      } else {
        credential = try await googleCredential()
      }
      _ = try await current.reauthenticate(with: credential)
    }
    catch {
      if let error = error as? GIDSignInError, error.code == .canceled { return .cancelled }
      if let error = error as? ASAuthorizationError, error.code == .canceled { return .cancelled }
      switch AuthErrorCode(rawValue: (error as NSError).code) {
      case .wrongPassword, .invalidCredential:
        return .failed("That password isn't right.")
      case .userMismatch:
        return .failed(signsInWithApple
                       ? "That's a different Apple ID. Use the one you use for Marquee."
                       : "That's a different Google account. Choose the one you use for Marquee.")
      case .networkError:
        return .failed("Couldn't reach the server. Check your connection and try again.")
      case .tooManyRequests:
        return .failed("Too many attempts. Wait a few minutes and try again.")
      default:
        return .failed(error.localizedDescription)
      }
    }
    // Apple requires apps to revoke their access when an account made with Sign in with Apple is deleted. Done
    // first, so if it fails nothing is deleted and they can try again
    if let appleAuthorizationCode {
      do {
        try await Auth.auth().revokeToken(withAuthorizationCode: appleAuthorizationCode)
      } catch {
        print(error)
        return .failed("Couldn't disconnect Marquee from your Apple ID. Check your connection and try again.")
      }
    }
    let message = await withCheckedContinuation { continuation in
      APIService.shared.deleteAccount(firebase_id: current.uid) { continuation.resume(returning: $0) }
    }
    return message.map { .failed($0) } ?? .deleted
  }

  /// UserDefaults keys that belong to the signed-in account, removed when it's deleted. Add new account keys here.
  /// Device settings (appearance.*) and whatever Firebase and Google Sign-In keep are left alone
  static let accountDefaultsKeys = [
    // Notifications and theatre check-ins
    NotificationManager.suggestionsKey, TheatreCheckIns.enabledKey,
    // AI and personalization
    Personalization.aiAllowedKey, Personalization.useAIKey, Personalization.aiConsentAskedKey,
    Personalization.ageRangeKey, Personalization.birthdayKey, Personalization.pronounsKey, "personalization.gender",
    // Discover: taste profile, reactions, deck, filters and quick add
    DiscoverViewModel.profileKey, DiscoverViewModel.likedKey, DiscoverViewModel.dislikedKey,
    "discover.passedMovieIDs", "discover.genreFilter", "discover.filters", "discover.kind", "discover.savedDeck",
    "discover.likedFilms", "discover.dislikedFilms",
    "discoverQuickAdd", "discoverQuickAddListID", "discoverQuickAddUsesAI",
    // Lists and their sharing, and cached film details
    "unrankedLists", "listVisibility", "aiPlacedFilms", "listSharing",
    "movieInfoCache", "genreCache", "imdbIDs", "filmographies",
  ]
  /// Prefixes of account keys made per list or per theatre: Tonight's Pick for each list, and the theatre the user
  /// was last at and the ones found near them
  static let accountDefaultsPrefixes = ["tonightsPick.", "theatreCheckIns."]

  /// Once the account is deleted: signs out and removes what the app kept on this phone for it
  func signOutDeletedAccount() {
    // Also unregisters this phone from notifications, turns off theatre check-ins and clears Core Data
    signOut()
    GIDSignIn.sharedInstance.signOut()
    let defaults = UserDefaults.standard
    for key in Self.accountDefaultsKeys { defaults.removeObject(forKey: key) }
    for key in defaults.dictionaryRepresentation().keys
    where Self.accountDefaultsPrefixes.contains(where: key.hasPrefix) {
      defaults.removeObject(forKey: key)
    }
    URLCache.shared.removeAllCachedResponses()
    // Lists saved by older versions of the app
    if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      try? FileManager.default.removeItem(at: documents.appendingPathComponent("db.sqlite3"))
    }
  }
}

enum AccountDeletionResult {
  case deleted
  // They closed Google or Apple sign-in without confirming
  case cancelled
  case failed(String)
}

enum AuthenticationError: Error {
  case tokenError(message: String)
}

extension AuthenticationViewModel {
  /// Shows Google sign-in and gives back a Firebase credential for the account picked
  private func googleCredential() async throws -> AuthCredential {
    guard let clientID = FirebaseApp.app()?.options.clientID else {
      fatalError("No client ID found in Firebase configuration")
    }
    let config = GIDConfiguration(clientID: clientID)
    GIDSignIn.sharedInstance.configuration = config

    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let rootViewController = window.rootViewController else {
      throw AuthenticationError.tokenError(message: "There is no root view controller!")
    }
    // Sheets (like Settings) present over the root, so Google's has to go over the top one
    var presenter = rootViewController
    while let presented = presenter.presentedViewController { presenter = presented }

    let userAuthentication = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)

    let user = userAuthentication.user
    guard let idToken = user.idToken else { throw AuthenticationError.tokenError(message: "ID token missing") }
    let accessToken = user.accessToken

    return GoogleAuthProvider.credential(withIDToken: idToken.tokenString,
                                         accessToken: accessToken.tokenString)
  }

  func signInWithGoogle() async -> Bool {
      do {
        let credential = try await googleCredential()

        let result = try await Auth.auth().signIn(with: credential)
        let firebaseUser = result.user
        // Signing in with Google for the first time creates the account
        if result.additionalUserInfo?.isNewUser == true {
          AppAnalytics.log(.signUp(.google))
        } else {
          AppAnalytics.log(.signIn(.google))
        }
          
        APIService.shared.createUser(firebase_id: firebaseUser.uid, email: firebaseUser.email ?? "no email", name: firebaseUser.displayName ?? "no name") { result in
            if case .failure(let error) = result { print(error.localizedDescription) }
            // New Google accounts have no username yet, which the app asks for once this has loaded
            SocialStore.shared.load()
        }
        print("User \(firebaseUser.uid) signed in with email \(firebaseUser.email ?? "unknown")")
          PersistenceController.shared.fetchAllCoreDataObjects(firebase_id: firebaseUser.uid)
        return true
      }
      catch {
        print(error.localizedDescription)
        self.errorMessage = error.localizedDescription
        return false
      }
  }
}

// MARK: - Sign in with Apple

extension AuthenticationViewModel {
  /// A random nonce for Sign in with Apple. Apple gets its SHA-256 hash and Firebase gets it as is, which proves
  /// the ID token was made for this sign-in
  static func randomNonce(length: Int = 32) -> String {
    let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var generator = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
  }

  static func sha256(_ input: String) -> String {
    SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Sets up the request from SignInWithAppleButton: the name and email, and the hash of a new nonce kept for the
  /// reply
  func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
    let nonce = Self.randomNonce()
    appleNonce = nonce
    request.requestedScopes = [.fullName, .email]
    request.nonce = Self.sha256(nonce)
  }

  /// A Firebase credential for an Apple sign-in. Apple only gives the name the first time, so it's passed on
  private func appleCredential(from apple: ASAuthorizationAppleIDCredential, nonce: String) throws -> AuthCredential {
    guard let tokenData = apple.identityToken, let idToken = String(data: tokenData, encoding: .utf8) else {
      throw AuthenticationError.tokenError(message: "Apple didn't send an ID token. Try again.")
    }
    return OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce, fullName: apple.fullName)
  }

  /// Finishes signing in with Apple from SignInWithAppleButton. Closing Apple's sheet isn't an error, so that
  /// returns false and leaves errorMessage empty
  func signInWithApple(_ result: Result<ASAuthorization, Error>) async -> Bool {
    errorMessage = ""
    let nonce = appleNonce
    appleNonce = nil
    do {
      let authorization = try result.get()
      guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential, let nonce else {
        throw AuthenticationError.tokenError(message: "Apple sign-in didn't finish. Try again.")
      }
      let credential = try appleCredential(from: apple, nonce: nonce)
      let result = try await Auth.auth().signIn(with: credential)
      let firebaseUser = result.user
      // Apple shares the name only on the first sign-in; it becomes the name shown on Home, Profile and to friends
      let fullName = apple.fullName
        .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !fullName.isEmpty, (firebaseUser.displayName ?? "").isEmpty {
        let change = firebaseUser.createProfileChangeRequest()
        change.displayName = fullName
        try? await change.commitChanges()
        self.user = Auth.auth().currentUser
      }
      // Signing in with Apple for the first time creates the account
      if result.additionalUserInfo?.isNewUser == true {
        AppAnalytics.log(.signUp(.apple))
      } else {
        AppAnalytics.log(.signIn(.apple))
      }
      let name = Auth.auth().currentUser?.displayName ?? ""
      APIService.shared.createUser(firebase_id: firebaseUser.uid, email: firebaseUser.email ?? "no email",
                                   name: name.isEmpty ? "no name" : name) { result in
        if case .failure(let error) = result { print(error.localizedDescription) }
        // New Apple accounts have no username yet, which the app asks for once this has loaded
        SocialStore.shared.load()
      }
      PersistenceController.shared.fetchAllCoreDataObjects(firebase_id: firebaseUser.uid)
      return true
    }
    catch {
      if let error = error as? ASAuthorizationError, error.code == .canceled { return false }
      print(error)
      if case AuthenticationError.tokenError(let message) = error {
        errorMessage = message
      } else {
        errorMessage = error.localizedDescription
      }
      return false
    }
  }
}

/// Runs Sign in with Apple without its button, to confirm it's them before deleting the account. Gives back
/// Apple's credential and the nonce its token was made with
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
  private var anchor = ASPresentationAnchor()

  @MainActor
  func signIn() async throws -> (credential: ASAuthorizationAppleIDCredential, nonce: String) {
    // Apple's sheet goes over the key window, which Settings is presented in
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    if let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first { anchor = window }
    let nonce = AuthenticationViewModel.randomNonce()
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.nonce = AuthenticationViewModel.sha256(nonce)
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    // The controller only holds its delegate weakly; this object stays alive here until Apple replies
    let credential = try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      controller.performRequests()
    }
    return (credential, nonce)
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    anchor
  }

  func authorizationController(controller: ASAuthorizationController,
                               didCompleteWithAuthorization authorization: ASAuthorization) {
    if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
      continuation?.resume(returning: credential)
    } else {
      continuation?.resume(throwing: AuthenticationError.tokenError(message: "Apple sign-in didn't finish. Try again."))
    }
    continuation = nil
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
