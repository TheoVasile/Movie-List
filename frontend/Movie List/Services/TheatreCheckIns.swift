//
//  TheatreCheckIns.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import CoreLocation
import MapKit
import UserNotifications

/// Theatre check-ins: when the user spends a film's worth of time at a movie theatre and leaves, a notification
/// asks what they saw. Works with any theatre Apple Maps knows about. The nearest ones are watched as regions
/// on the iPhone (iOS allows 20 per app), refreshed as the user moves; nothing about where they go is sent anywhere
final class TheatreCheckIns: NSObject, ObservableObject {
    static let shared = TheatreCheckIns()

    static let enabledKey = "notify.theatreCheckIns"

    @Published private(set) var authorization: CLAuthorizationStatus
    // Off when the user only allowed approximate location, which region monitoring can't work with
    @Published private(set) var preciseLocation: Bool

    private let locationManager = CLLocationManager()
    // Set while turning on, so the Always prompt only follows the When In Use one when the user asked for it
    private var upgradingToAlways = false

    private static let regionPrefix = "theatre-"
    private static let namesKey = "theatreCheckIns.names"
    private static let arrivalKey = "theatreCheckIns.arrival"
    private static let lastNotifiedKey = "theatreCheckIns.lastNotified"
    private static let searchLatitudeKey = "theatreCheckIns.searchLatitude"
    private static let searchLongitudeKey = "theatreCheckIns.searchLongitude"
    private static let notificationPurposeKey = "TheatreCheckIns"

    private static let searchRadius: CLLocationDistance = 20_000
    // Theatres are looked for again once the user is this far from where they last were
    private static let refreshDistance: CLLocationDistance = 5_000
    private static let regionRadius: CLLocationDistance = 150
    // One region is left over for anything else in the app
    private static let maxTheatres = 19
    // Shorter than most films (with trailers), and longer than most cinema visits that aren't one
    private static let minimumVisit: TimeInterval = 75 * 60
    private static let maximumVisit: TimeInterval = 5 * 60 * 60
    // Back-to-back exits, or GPS jitter at the door, only ask once
    private static let notificationGap: TimeInterval = 3 * 60 * 60

    private override init() {
        authorization = locationManager.authorizationStatus
        preciseLocation = locationManager.accuracyAuthorization == .fullAccuracy
        super.init()
        locationManager.delegate = self
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var canMonitor: Bool {
        isEnabled && authorization == .authorizedAlways && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    /// Called at launch from AppDelegate; resumes monitoring if enabled (iOS relaunches the app in the background
    /// for region events, so the manager and its delegate have to exist by then)
    func configure() {
        if canMonitor {
            startMonitoring()
        }
    }

    /// Turning on asks for When In Use and then Always permission (and temporary full accuracy if the user only
    /// allowed approximate location), finds theatres and starts monitoring; turning off stops all monitoring and
    /// clears what was stored
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        guard on else {
            upgradingToAlways = false
            stopMonitoring()
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            upgradingToAlways = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            requestFullAccuracyIfNeeded()
            startMonitoring()
        default:
            // Denied or restricted: only Settings can change it
            break
        }
        if NotificationManager.shared.authorization == .notDetermined {
            NotificationManager.shared.requestPermission()
        }
    }

    private func requestFullAccuracyIfNeeded() {
        guard locationManager.accuracyAuthorization == .reducedAccuracy else { return }
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.notificationPurposeKey)
    }

    // MARK: - Monitoring

    private var theatreRegions: [CLRegion] {
        locationManager.monitoredRegions.filter { $0.identifier.hasPrefix(Self.regionPrefix) }
    }

    private func startMonitoring() {
        guard canMonitor else { return }
        locationManager.startMonitoringSignificantLocationChanges()
        if let location = locationManager.location, location.timestamp.timeIntervalSinceNow > -15 * 60 {
            refreshTheatresIfMoved(to: location)
        } else {
            locationManager.requestLocation()
        }
    }

    private func stopMonitoring() {
        locationManager.stopMonitoringSignificantLocationChanges()
        for region in theatreRegions {
            locationManager.stopMonitoring(for: region)
        }
        let defaults = UserDefaults.standard
        for key in [Self.namesKey, Self.arrivalKey, Self.lastNotifiedKey, Self.searchLatitudeKey, Self.searchLongitudeKey] {
            defaults.removeObject(forKey: key)
        }
    }

    private func refreshTheatresIfMoved(to location: CLLocation) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.searchLatitudeKey) != nil, !theatreRegions.isEmpty {
            let last = CLLocation(latitude: defaults.double(forKey: Self.searchLatitudeKey),
                                  longitude: defaults.double(forKey: Self.searchLongitudeKey))
            guard location.distance(from: last) > Self.refreshDistance else { return }
        }
        findTheatres(near: location)
    }

    /// Looks up movie theatres around the user with Apple Maps and watches the nearest ones in place of the old set
    private func findTheatres(near location: CLLocation) {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: Self.searchRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.movieTheater])
        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                guard self.canMonitor else { return }
                guard let response else {
                    print("Couldn't find movie theatres:", error?.localizedDescription ?? "no response")
                    return
                }
                UserDefaults.standard.set(location.coordinate.latitude, forKey: Self.searchLatitudeKey)
                UserDefaults.standard.set(location.coordinate.longitude, forKey: Self.searchLongitudeKey)
                let nearest = response.mapItems
                    .compactMap { item -> (id: String, name: String, location: CLLocation)? in
                        guard let place = item.placemark.location else { return nil }
                        let id = Self.regionPrefix + String(format: "%.5f,%.5f", place.coordinate.latitude, place.coordinate.longitude)
                        return (id, item.name ?? "the movie theatre", place)
                    }
                    .sorted { $0.location.distance(from: location) < $1.location.distance(from: location) }
                    .prefix(Self.maxTheatres)
                self.monitor(Array(nearest))
            }
        }
    }

    private func monitor(_ theatres: [(id: String, name: String, location: CLLocation)]) {
        var keep = Set(theatres.map(\.id))
        // The theatre the user is in stays watched, so leaving it still counts
        if let arrival = self.arrival {
            keep.insert(arrival.id)
        }
        var names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        names = names.filter { keep.contains($0.key) }
        let watched = Set(theatreRegions.map(\.identifier))
        for region in theatreRegions where !keep.contains(region.identifier) {
            locationManager.stopMonitoring(for: region)
        }
        let radius = min(Self.regionRadius, locationManager.maximumRegionMonitoringDistance)
        for theatre in theatres {
            names[theatre.id] = theatre.name
            guard !watched.contains(theatre.id) else { continue }
            let region = CLCircularRegion(center: theatre.location.coordinate, radius: radius, identifier: theatre.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
        }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
    }

    // MARK: - Visits

    /// The theatre the user is at and when they got there, kept in UserDefaults since the app is often not running
    private var arrival: (id: String, date: Date)? {
        get {
            guard let stored = UserDefaults.standard.dictionary(forKey: Self.arrivalKey),
                  let id = stored["id"] as? String, let time = stored["time"] as? Double else { return nil }
            return (id, Date(timeIntervalSince1970: time))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(["id": newValue.id, "time": newValue.date.timeIntervalSince1970], forKey: Self.arrivalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.arrivalKey)
            }
        }
    }

    private func theatreName(_ id: String) -> String {
        (UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String])?[id] ?? "the movie theatre"
    }

    private func arrived(at id: String) {
        // A visit already under way wins, unless it's too old to have been real (its exit was missed)
        if let current = arrival, -current.date.timeIntervalSinceNow < Self.maximumVisit {
            return
        }
        arrival = (id, Date())
    }

    private func left(_ id: String) {
        guard let current = arrival, current.id == id else { return }
        arrival = nil
        let stayed = -current.date.timeIntervalSinceNow
        guard (Self.minimumVisit...Self.maximumVisit).contains(stayed) else { return }
        let defaults = UserDefaults.standard
        let lastNotified = defaults.double(forKey: Self.lastNotifiedKey)
        guard Date().timeIntervalSince1970 - lastNotified > Self.notificationGap else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastNotifiedKey)

        let name = theatreName(id)
        let content = UNMutableNotificationContent()
        content.title = "Just saw a movie?"
        content.body = "You were at \(name). Tap to add what you saw to a list."
        content.sound = .default
        content.userInfo = ["type": "theatre_visit", "theatre": name]
        let identifier = "theatre-visit-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

extension TheatreCheckIns: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        guard isEnabled else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse where upgradingToAlways:
            // iOS asks for Always as a second step, after When In Use
            upgradingToAlways = false
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            upgradingToAlways = false
            requestFullAccuracyIfNeeded()
            startMonitoring()
        case .authorizedWhenInUse:
            break
        default:
            // Permission was taken away; the switch stays on so check-ins resume if it's given back
            upgradingToAlways = false
            for region in theatreRegions {
                manager.stopMonitoring(for: region)
            }
            manager.stopMonitoringSignificantLocationChanges()
            arrival = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard canMonitor, let location = locations.last else { return }
        refreshTheatresIfMoved(to: location)
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        // Someone already inside when monitoring starts gets no entry event, so ask
        guard region.identifier.hasPrefix(Self.regionPrefix) else { return }
        manager.requestState(for: region)
    }

    // Called for every boundary crossing as well as for requestState, so entries and exits are handled here only
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier.hasPrefix(Self.regionPrefix), canMonitor else { return }
        switch state {
        case .inside: arrived(at: region.identifier)
        case .outside: left(region.identifier)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier.hasPrefix(Self.regionPrefix) ?? true else { return }
        print("Couldn't watch a movie theatre:", error.localizedDescription)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Couldn't get location for theatre check-ins:", error.localizedDescription)
    }
}
