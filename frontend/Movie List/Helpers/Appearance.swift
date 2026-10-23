//
//  Appearance.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI
import UIKit
import CoreLocation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system, daylight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match iPhone"
        case .daylight: return "Daylight"
        }
    }

    var icon: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return "iphone"
        case .daylight: return "sunrise.fill"
        }
    }
}

/// The app's colours. Pink is offered only to the accounts in `pinkHandles`
enum ColorTheme: String, CaseIterable, Identifiable {
    case classic, pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .pink: return "Pink"
        }
    }

    static let pinkHandles: Set<String> = ["bitchpickles", "rogueaxis3301"]

    static func isAvailable(_ theme: ColorTheme, to handle: String?) -> Bool {
        theme == .classic || handle.map { pinkHandles.contains($0) } == true
    }
}

/// The app's light/dark setting. Daylight mode is light between sunrise and sunset and dark otherwise.
/// Sun times come from the device's approximate location if the user allows it, rounded to about
/// 10 km and kept on this device only; without it, daytime is 7 AM to 7 PM
final class AppearanceSettings: NSObject, ObservableObject {
    static let shared = AppearanceSettings()

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .daylight {
                requestLocation()
            }
            refresh()
        }
    }
    @Published var colorTheme: ColorTheme {
        didSet {
            UserDefaults.standard.set(colorTheme.rawValue, forKey: Self.colorThemeKey)
            Theme.isPink = colorTheme == .pink
            redraw()
        }
    }
    @Published private(set) var sunTimes: SunTimes
    @Published private(set) var usesLocation: Bool

    private let locationManager = CLLocationManager()
    private var timer: Timer?

    private static let modeKey = "appearance.mode"
    private static let colorThemeKey = "appearance.colorTheme"
    private static let latitudeKey = "appearance.latitude"
    private static let longitudeKey = "appearance.longitude"

    private override init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(AppearanceMode.init) ?? .dark
        let savedTheme = UserDefaults.standard.string(forKey: Self.colorThemeKey).flatMap(ColorTheme.init) ?? .classic
        colorTheme = savedTheme
        Theme.isPink = savedTheme == .pink
        usesLocation = UserDefaults.standard.object(forKey: Self.latitudeKey) != nil
        sunTimes = SunTimes.fallback(on: Date())
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyReduced
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromNotification),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }

    private var coordinate: (latitude: Double, longitude: Double)? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.latitudeKey) != nil else { return nil }
        return (defaults.double(forKey: Self.latitudeKey), defaults.double(forKey: Self.longitudeKey))
    }

    var isDaytime: Bool {
        sunTimes.isDaytime(at: Date())
    }

    /// The style every window should use, or `.unspecified` to follow the iPhone's own setting
    var interfaceStyle: UIUserInterfaceStyle {
        switch mode {
        case .dark: return .dark
        case .light: return .light
        case .system: return .unspecified
        case .daylight: return isDaytime ? .light : .dark
        }
    }

    @objc private func refreshFromNotification() {
        refresh()
    }

    /// Recomputes today's sun times and applies the resulting style. While in daylight mode, checks
    /// again every minute so the switch happens close to sunrise and sunset
    func refresh() {
        let now = Date()
        if let coordinate {
            sunTimes = SunTimes(on: now, latitude: coordinate.latitude, longitude: coordinate.longitude)
        } else {
            sunTimes = SunTimes.fallback(on: now)
        }
        timer?.invalidate()
        timer = nil
        if mode == .daylight {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.applyIfChanged()
            }
        }
        apply()
    }

    private func applyIfChanged() {
        if !Calendar.current.isDate(sunTimes.sunrise, inSameDayAs: Date()) {
            refresh()
        } else if currentWindows.contains(where: { $0.overrideUserInterfaceStyle != interfaceStyle }) {
            apply()
            objectWillChange.send()
        }
    }

    private var currentWindows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    /// Falls back to Classic when the signed-in account can't use the chosen theme (after signing out, say)
    func checkColorTheme(for handle: String?) {
        if !ColorTheme.isAvailable(colorTheme, to: handle) { colorTheme = .classic }
    }

    // The app's screens are built again for the new theme (see Movie_ListApp); this fades between the two and
    // has UIKit's own parts, like the tab bar, pick up the new colours
    private func redraw() {
        let style = interfaceStyle
        for window in currentWindows {
            let current = window.traitCollection.userInterfaceStyle
            UIView.transition(with: window, duration: 0.35, options: .transitionCrossDissolve) {
                window.overrideUserInterfaceStyle = current == .dark ? .light : .dark
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    /// Sets the style on every window, so sheets and alerts follow it too
    func apply() {
        let style = interfaceStyle
        for window in currentWindows where window.overrideUserInterfaceStyle != style {
            UIView.transition(with: window, duration: 0.35, options: .transitionCrossDissolve) {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        default:
            break
        }
    }
}

extension AppearanceSettings: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if mode == .daylight, [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // About 10 km is plenty for sun times, and keeps the stored location vague
        let round = { (value: Double) in (value * 10).rounded() / 10 }
        UserDefaults.standard.set(round(location.coordinate.latitude), forKey: Self.latitudeKey)
        UserDefaults.standard.set(round(location.coordinate.longitude), forKey: Self.longitudeKey)
        DispatchQueue.main.async {
            self.usesLocation = true
            self.refresh()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Couldn't get location for sun times:", error.localizedDescription)
    }
}

/// Sunrise and sunset for one day
struct SunTimes {
    let sunrise: Date
    let sunset: Date

    func isDaytime(at date: Date) -> Bool {
        sunrise <= date && date < sunset
    }

    /// 7 AM to 7 PM, used when the location isn't known
    static func fallback(on date: Date) -> SunTimes {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return SunTimes(sunrise: calendar.date(byAdding: .hour, value: 7, to: start)!,
                        sunset: calendar.date(byAdding: .hour, value: 19, to: start)!)
    }

    private init(sunrise: Date, sunset: Date) {
        self.sunrise = sunrise
        self.sunset = sunset
    }

    /// NOAA's approximate solar equations, accurate to a minute or two
    init(on date: Date, latitude: Double, longitude: Double) {
        let calendar = Calendar.current
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1)
        let equationOfTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let lat = latitude * .pi / 180
        // 90.833° allows for refraction and the sun's radius
        let cosHourAngle = cos(90.833 * .pi / 180) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)

        // Midnight UTC on this local calendar day
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let utcMidnight = utc.date(from: parts) ?? calendar.startOfDay(for: date)
        let localStart = calendar.startOfDay(for: date)

        if cosHourAngle > 1 {
            // Polar night: the sun never rises
            self.init(sunrise: localStart, sunset: localStart)
        } else if cosHourAngle < -1 {
            // Midnight sun: it never sets
            self.init(sunrise: localStart, sunset: calendar.date(byAdding: .day, value: 1, to: localStart)!)
        } else {
            let hourAngle = acos(cosHourAngle) * 180 / .pi
            let sunriseMinutes = 720 - 4 * (longitude + hourAngle) - equationOfTime
            let sunsetMinutes = 720 - 4 * (longitude - hourAngle) - equationOfTime
            self.init(sunrise: utcMidnight.addingTimeInterval(sunriseMinutes * 60),
                      sunset: utcMidnight.addingTimeInterval(sunsetMinutes * 60))
        }
    }
}
