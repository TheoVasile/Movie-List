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
        self.displayName = user?.email ?? ""
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
        return true
    }
    catch  {
      print(error)
      errorMessage = error.localizedDescription
      authenticationState = .unauthenticated
      return false
    }
  }

    func signUpWithEmailPassword(name: String) async -> Bool {
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
            
            APIService.shared.createUser(firebase_id: firebaseUser.uid, email: firebaseUser.email ?? "no email", name: displayName) { result in
                switch result {
                case .success( _):
                    print("created user")
                case .failure(let error):
                    print(error.localizedDescription)
                }
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
        PersistenceController.shared.deleteAllCoreDataObjects()
        SyncStatus.shared.reset()
        // The next person to sign in shouldn't see this account's films on the Home Screen
        WidgetSnapshot.remove()
        WidgetCenter.shared.reloadAllTimelines()
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

  func deleteAccount() async -> Bool {
    do {
      try await user?.delete()
      return true
    }
    catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}

enum AuthenticationError: Error {
  case tokenError(message: String)
}

extension AuthenticationViewModel {
  func signInWithGoogle() async -> Bool {
    guard let clientID = FirebaseApp.app()?.options.clientID else {
      fatalError("No client ID found in Firebase configuration")
    }
    let config = GIDConfiguration(clientID: clientID)
    GIDSignIn.sharedInstance.configuration = config

    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let rootViewController = window.rootViewController else {
      print("There is no root view controller!")
      return false
    }

      do {
        let userAuthentication = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)

        let user = userAuthentication.user
        guard let idToken = user.idToken else { throw AuthenticationError.tokenError(message: "ID token missing") }
        let accessToken = user.accessToken

        let credential = GoogleAuthProvider.credential(withIDToken: idToken.tokenString,
                                                       accessToken: accessToken.tokenString)

        let result = try await Auth.auth().signIn(with: credential)
        let firebaseUser = result.user
          
        APIService.shared.createUser(firebase_id: firebaseUser.uid, email: firebaseUser.email ?? "no email", name: firebaseUser.displayName ?? "no name") { result in
            switch result {
            case .success( _):
                print("created user")
            case .failure(let error):
                print(error.localizedDescription)
            }
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
