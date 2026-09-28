//
//  WeatherBarItem.swift
//  MTMR
//
//  Created by Daniel Apatin on 18.04.2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa
import CoreLocation

class WeatherBarItem: CustomButtonTouchBarItem, CLLocationManagerDelegate {
    private let activity: NSBackgroundActivityScheduler
    private var units: String
    private var api_key: String
    private var units_str = "°F"
    private var prev_location: CLLocation!
    private var location: CLLocation!
    private let iconsImages = ["01d": "☀️", "01n": "☀️", "02d": "⛅️", "02n": "⛅️", "03d": "☁️", "03n": "☁️", "04d": "☁️", "04n": "☁️", "09d": "⛅️", "09n": "⛅️", "10d": "🌦", "10n": "🌦", "11d": "🌩", "11n": "🌩", "13d": "❄️", "13n": "❄️", "50d": "🌫", "50n": "🌫"]
    private let iconsText = ["01d": "☀", "01n": "☀", "02d": "☁", "02n": "☁", "03d": "☁", "03n": "☁", "04d": "☁", "04n": "☁", "09d": "☂", "09n": "☂", "10d": "☂", "10n": "☂", "11d": "☈", "11n": "☈", "13d": "☃", "13n": "☃", "50d": "♨", "50n": "♨"]
    private var iconsSource: Dictionary<String, String>

    private var manager: CLLocationManager!

    init(identifier: NSTouchBarItem.Identifier, interval: TimeInterval, units: String, api_key: String, icon_type: String? = "text") {
        activity = NSBackgroundActivityScheduler(identifier: "\(identifier.rawValue).updatecheck")
        activity.interval = interval
        self.units = units
        self.api_key = api_key

        if self.units == "metric" {
            units_str = "°C"
        }

        if self.units == "imperial" {
            units_str = "°F"
        }

        if icon_type == "images" {
            iconsSource = iconsImages
        } else {
            iconsSource = iconsText
        }

        super.init(identifier: identifier, title: "")
        hideUntilFirstTitle()

        let status = CLLocationManager.authorizationStatus()
        if status == .restricted || status == .denied {
            print("User permission not given")
            return
        }

        if !CLLocationManager.locationServicesEnabled() {
            print("Location services not enabled")
            return
        }

        activity.repeats = true
        activity.qualityOfService = .utility
        activity.schedule { (completion: NSBackgroundActivityScheduler.CompletionHandler) in
            self.updateWeather()
            completion(NSBackgroundActivityScheduler.Result.finished)
        }
        updateWeather()

        manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.startUpdatingLocation()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func updateWeather() {
        if location != nil {
            let urlRequest = URLRequest(url: URL(string: "https://api.openweathermap.org/data/2.5/weather?lat=\(location.coordinate.latitude)&lon=\(location.coordinate.longitude)&units=\(units)&appid=\(api_key)")!)

            let task = URLSession.shared.dataTask(with: urlRequest) { data, _, error in

                if error == nil {
                    do {
                        let json = try JSONSerialization.jsonObject(with: data!, options: .mutableContainers) as! [String: AnyObject]
//                        print(json)
                        var temperature: Int!
                        var condition_icon = ""
                        var iconCode = ""
                        var low: Int?, high: Int?

                        if let main = json["main"] as? [String: AnyObject] {
                            if let temp = main["temp"] as? Double {
                                temperature = Int(temp)
                            }
                            low = (main["temp_min"] as? Double).map { Int($0.rounded()) }
                            high = (main["temp_max"] as? Double).map { Int($0.rounded()) }
                        }

                        if let weather = json["weather"] as? NSArray, let item = weather[0] as? NSDictionary {
                            let icon = item["icon"] as! String
                            iconCode = icon
                            if let test = self.iconsSource[icon] {
                                condition_icon = test
                            }
                        }

                        if temperature != nil {
                            DispatchQueue.main.async {
                                if self.theme.stripeWidgets {
                                    self.showStripe(temperature: temperature, icon: iconCode, low: low, high: high)
                                } else {
                                    self.setWeather(text: "\(condition_icon) \(temperature!)\(self.units_str)")
                                }
                            }
                        }
                    } catch let jsonError {
                        print(jsonError.localizedDescription)
                    }
                }
            }

            task.resume()
        }
    }

    func setWeather(text: String) {
        title = text
    }

    /// Stripe's weather: the condition as a colored symbol, the temperature in
    /// bold, and the day's high and low stacked small beside it.
    private func showStripe(temperature: Int, icon: String, low: Int?, high: Int?) {
        let (symbol, color) = WeatherBarItem.condition(icon)
        if style.symbol == nil {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: color)))
        }
        let text = NSMutableAttributedString(attributedString: StripeReadout.figure("\(temperature)°"))
        if let low = low, let high = high {
            text.append(StripeReadout.gap(5))
            text.append(StripeReadout.stacked(StripeReadout.small("H \(high)"), StripeReadout.small("L \(low)")))
        }
        attributedTitle = text
    }

    /// OpenWeather's icon code as an SF Symbol and its colors (day and night alike).
    static func condition(_ code: String) -> (String, [NSColor]) {
        let sun = NSColor(srgbRed: 1, green: 0xD6 / 255, blue: 0x0A / 255, alpha: 1)
        let cloud = NSColor(white: 0.9, alpha: 1)
        let rain = NSColor(srgbRed: 0x64 / 255, green: 0xD2 / 255, blue: 1, alpha: 1)
        let night = code.hasSuffix("n")
        switch code.prefix(2) {
        case "01": return night ? ("moon.stars.fill", [cloud, sun]) : ("sun.max.fill", [sun])
        case "02": return night ? ("cloud.moon.fill", [cloud, sun]) : ("cloud.sun.fill", [cloud, sun])
        case "03", "04": return ("cloud.fill", [cloud])
        case "09", "10": return ("cloud.rain.fill", [cloud, rain])
        case "11": return ("cloud.bolt.rain.fill", [cloud, sun])
        case "13": return ("snowflake", [cloud])
        case "50": return ("cloud.fog.fill", [cloud])
        default: return ("thermometer.medium", [cloud])
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let lastLocation = locations.last!
        location = lastLocation
        if prev_location == nil {
            updateWeather()
        }
        prev_location = lastLocation
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        print(error)
    }

    func locationManager(_: CLLocationManager, didChangeAuthorization _: CLAuthorizationStatus) {
//        print("inside didChangeAuthorization ");
        updateWeather()
    }
    
    deinit {
        activity.invalidate()
    }
}
